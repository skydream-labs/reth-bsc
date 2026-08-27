#!/usr/bin/env python3
import pathlib, shutil, datetime
p = pathlib.Path("poc.sh"); s = p.read_text()
shutil.copy(p, "poc.sh.bak-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
if "port RPC dari cmdline proses" in s:
    raise SystemExit("v12 sudah terpatch")

OLD = '''echo "    [8a] start node kontrol geth (bsc_fullnode.sh reset 0 full)..."
( cd "$DEPLOY_DIR" && bash ./bsc_fullnode.sh reset 0 full ) >"$OUT/fullnode.log" 2>&1 \\
  || { echo "FATAL: bsc_fullnode.sh reset gagal — tail $OUT/fullnode.log:"; tail -10 "$OUT/fullnode.log"; exit 1; }
CRPC=""
for i in $(seq 1 90); do
  for p in $(grep -rhoE '^HTTPPort *= *[0-9]+' "$DEPLOY_DIR"/.local/fullnode*/config.toml 2>/dev/null | grep -oE '[0-9]+$' | sort -u); do
    if curl -s -m 2 -X POST -H 'Content-Type: application/json' \\
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \\
      "http://127.0.0.1:$p" 2>/dev/null | grep -q '"result"'; then
      CRPC="http://127.0.0.1:$p"; break 2
    fi
  done
  sleep 2
done
[ -n "$CRPC" ] || { echo "FATAL: RPC fullnode kontrol tidak ditemukan (cek $OUT/fullnode.log)"; exit 1; }'''

NEW = '''echo "    [8a] start node kontrol geth (bsc_fullnode.sh reset 0 full)..."
( cd "$DEPLOY_DIR" && bash ./bsc_fullnode.sh reset 0 full ) >"$OUT/fullnode.log" 2>&1 \\
  || { echo "FATAL: bsc_fullnode.sh reset gagal — tail $OUT/fullnode.log:"; tail -10 "$OUT/fullnode.log"; exit 1; }
# reset bisa hanya init — pastikan proses hidup (restart = stop+start)
sleep 3
if ! pgrep -f 'fullnode/node0' >/dev/null 2>&1; then
  echo "    reset tidak meninggalkan proses — jalankan 'restart 0 full'..."
  ( cd "$DEPLOY_DIR" && bash ./bsc_fullnode.sh restart 0 full ) >>"$OUT/fullnode.log" 2>&1 || true
fi
# port RPC dari cmdline proses (flag --http.port); fallback config lokal
CRPC=""
for i in $(seq 1 90); do
  FP=$(pgrep -f 'fullnode/node0' | head -n1)
  if [ -n "$FP" ]; then
    FPT=$(tr '\\0' ' ' < "/proc/$FP/cmdline" 2>/dev/null | grep -oE '\\-\\-http\\.port [0-9]+' | awk '{print $2}' | head -n1)
    if [ -z "$FPT" ]; then
      FPT=$(grep -hoE '^HTTPPort *= *[0-9]+' "$DEPLOY_DIR"/.local/fullnode/node0/config.toml 2>/dev/null | grep -oE '[0-9]+' | head -n1)
    fi
    if [ -n "$FPT" ] && curl -s -m 2 -X POST -H 'Content-Type: application/json' \\
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \\
      "http://127.0.0.1:$FPT" 2>/dev/null | grep -q '"result"'; then
      CRPC="http://127.0.0.1:$FPT"; break
    fi
  fi
  sleep 2
done
[ -n "$CRPC" ] || {
  echo "FATAL: RPC fullnode kontrol tidak ditemukan."
  echo "--- proses fullnode:"; pgrep -af fullnode || echo "(tidak ada)"
  echo "--- isi .local/fullnode/node0:"; ls "$DEPLOY_DIR/.local/fullnode/node0/" 2>/dev/null
  echo "--- log runtime (bsc-node.log tail):"
  tail -30 "$DEPLOY_DIR/.local/fullnode/node0/bsc-node.log" 2>/dev/null || echo "(tidak ada)"
  echo "--- fullnode.log tail:"; tail -10 "$OUT/fullnode.log"
  exit 1
}'''

assert OLD in s, "anchor [8a] lama tidak ditemukan"
s = s.replace(OLD, NEW, 1)
p.write_text(s)
print("[+] [8a] v12: pgrep-ensure + port dari /proc cmdline + dump diagnostik saat FATAL")
