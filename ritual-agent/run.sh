#!/usr/bin/env bash
# run.sh - manage a recurring sovereign agent on Ritual testnet (chain 1979).
# Commands: deploy (default), view, topup. Keyless Ritual LLM, signs from an
# encrypted keystore (set up on first run), and auto-installs foundry + uv if missing.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

### ---------- look and feel ----------
# Color only when stdout is a real terminal and the user has not opted out via NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  ESC=$'\033'
  RESET="${ESC}[0m"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"; CLR="${ESC}[K"
  ACCENT="${ESC}[38;5;141m"; OKC="${ESC}[38;5;78m"; BADC="${ESC}[38;5;203m"
  WARNC="${ESC}[38;5;214m"; MUTED="${ESC}[38;5;244m"; HIDE="${ESC}[?25l"; SHOW="${ESC}[?25h"
  USE_COLOR=1
else
  ESC=; RESET=; BOLD=; DIM=; CLR=; ACCENT=; OKC=; BADC=; WARNC=; MUTED=; HIDE=; SHOW=; USE_COLOR=0
fi

LOGFILE="$(mktemp)"
cleanup() { printf '%s' "$SHOW"; rm -f "$LOGFILE" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# Paint a short ASCII string letter by letter through a purple-to-pink ramp.
gradient() {
  if [ "$USE_COLOR" != 1 ]; then printf '%s' "$1"; return; fi
  local text="$1" ramp=(99 105 141 147 183 219 213) i=0
  while [ "$i" -lt "${#text}" ]; do
    printf '%s[1;38;5;%sm%s' "$ESC" "${ramp[i % ${#ramp[@]}]}" "${text:i:1}"
    i=$((i + 1))
  done
  printf '%s' "$RESET"
}

BANNER_SHOWN=0
hr()     { printf '  %s--------------------------------------------%s\n' "$MUTED" "$RESET"; }
banner() {
  [ "$BANNER_SHOWN" = 1 ] && return 0; BANNER_SHOWN=1
  printf '\n  '; gradient "RITUAL SOVEREIGN AGENT"; printf '\n'
  printf '  %srecurring keyless agent - Ritual testnet (1979)%s\n' "$DIM" "$RESET"
  printf '  %sbuilt by Zun  %shttps://x.com/Zun2025%s\n' "$MUTED" "$ACCENT" "$RESET"; hr
}
step() { printf '\n  %s>%s %s%s%s\n' "$ACCENT" "$RESET" "$BOLD" "$1" "$RESET"; }
info() { printf '    %s%s%s\n' "$MUTED" "$1" "$RESET"; }
ok()   { printf '  %sok%s %s\n' "$OKC" "$RESET" "$1"; }
warn() { printf '  %s!%s  %s\n' "$WARNC" "$RESET" "$1"; }
kv()   { printf '  %s%-11s%s %s\n' "$MUTED" "$1" "$RESET" "$2"; }

# Braille spinner glyphs only render on a UTF-8 terminal; on a legacy/C-locale terminal they turn
# into mojibake or blanks. Detect UTF-8 from the locale (with a `locale charmap` cross-check) and
# fall back to a plain ASCII spinner everywhere else.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UTF8=1 ;;
  *) UTF8=0 ;;
esac
if [ "$UTF8" = 0 ] && command -v locale >/dev/null 2>&1; then
  case "$(locale charmap 2>/dev/null)" in [Uu][Tt][Ff]-8 | [Uu][Tt][Ff]8) UTF8=1 ;; esac
fi

# Run a command behind a spinner; output is captured and shown only on failure. An optional leading
# integer retries the command that many times (for flaky network steps).
if [ "$UTF8" = 1 ]; then
  SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
  SPIN_FRAMES=('|' '/' '-' '\')
fi
spin() {
  local tries=1
  case "$1" in '' | *[!0-9]*) ;; *) tries="$1"; shift ;; esac
  local msg="$1"; shift
  local attempt rc=1 pid i
  for attempt in $(seq 1 "$tries"); do
    if [ "$USE_COLOR" != 1 ]; then
      printf '  %s ... ' "$msg"
      if "$@" >"$LOGFILE" 2>&1; then echo "ok"; return 0; else rc=$?; fi
    else
      "$@" >"$LOGFILE" 2>&1 &
      pid=$!; i=0; printf '%s' "$HIDE"
      while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$ACCENT" "${SPIN_FRAMES[i % ${#SPIN_FRAMES[@]}]}" "$RESET" "$msg"
        i=$((i + 1)); sleep 0.08
      done
      if wait "$pid"; then rc=0; else rc=$?; fi
      printf '%s' "$SHOW"
      if [ "$rc" -eq 0 ]; then printf '\r  %sok%s %s%s\n' "$OKC" "$RESET" "$msg" "$CLR"; return 0; fi
    fi
    [ "$attempt" -lt "$tries" ] && { printf '\r  %s~%s %s (retry %s/%s)%s\n' "$WARNC" "$RESET" "$msg" "$((attempt + 1))" "$tries" "$CLR"; sleep 1; }
  done
  [ "$USE_COLOR" = 1 ] && printf '\r  %sx%s %s%s\n' "$BADC" "$RESET" "$msg" "$CLR" || echo "failed"
  sed 's/^/      /' "$LOGFILE"
  return "$rc"
}

usage() {
  banner
  cat <<EOF
  ${BOLD}Usage${RESET}  bash run.sh [command] [args]

  ${ACCENT}deploy${RESET}                    deploy + fund + arm (shows your agents, then asks before adding another)
  ${ACCENT}view${RESET} [eoa]                list every agent an EOA deployed: live/dead + stuck RITUAL
  ${ACCENT}topup${RESET} [address] [amount]  deposit more RITUAL into an agent's wallet
  ${ACCENT}help${RESET}                      show this help

  view defaults to your own wallet. topup with no address -> the agent for SALT in .env.
  Amounts are in RITUAL. Lock duration: LOCK_BLOCKS (default 100000).

  Note: stop/restart/withdraw are not exposed - a bug in Ritual's proxy contract makes
  them revert today. They should work once the Ritual team upgrades the proxy.
EOF
}

### ---------- config + helpers ----------
CMD="${1:-deploy}"; shift || true
CMD="${CMD#--}"
case "$CMD" in help|-h|"") usage; exit 0 ;; esac

fail() { printf '\n  %sERROR%s %s\n' "$BADC" "$RESET" "$1" >&2; exit 1; }

[ -f "$HERE/.env" ] || fail ".env not found. Run: cp .env.example .env  then edit it."
# Parse .env instead of sourcing it: keep values with spaces (PROMPT) literal, strip CRLF and
# surrounding quotes, skip blanks/comments. Sourcing would run "Say hello world" as a command.
while IFS='=' read -r key val || [ -n "$key" ]; do
  key="${key%$'\r'}"; val="${val%$'\r'}"
  case "$key" in ''|\#*|*[!A-Za-z0-9_]*) continue ;; esac
  case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
  export "$key=$val"
done < "$HERE/.env"

# Ritual testnet system contracts
FACTORY="0x9dC4C054e53bCc4Ce0A0Ff09E890A7a8e817f304"
RITUAL_WALLET="0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948"
SCHEDULER="0x56e776bae2dd60664b69bd5f865f1180ffb7d58b"
export REGISTRY="0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F"
export LOCK_BLOCKS="${LOCK_BLOCKS:-100000}"

# A sovereign run costs ~0.5-1 RITUAL (varies by model, iterations, tool calls). Require at least
# 1 RITUAL per deploy so a wake can be funded; below that the job is under-funded and silently
# dropped. Enforced on deploy only - top-ups are additive, so any amount is fine.
MIN_DEPOSIT_WEI=1000000000000000000   # 1 RITUAL
need_deposit() { [ -n "${DEPOSIT:-}" ] || fail "DEPOSIT is required (in RITUAL, e.g. DEPOSIT=1)"; }
require_min_deposit() {
  awk -v d="$DEPOSIT_WEI" -v m="$MIN_DEPOSIT_WEI" 'BEGIN{exit !(d+0 >= m+0)}' \
    || fail "DEPOSIT=$DEPOSIT RITUAL is below the 1 RITUAL minimum. A run costs ~0.5-1 RITUAL; fund at least 1 (5 recommended)."
}
num() { printf '%s' "${1%% *}"; }  # strip cast's trailing "[1.5e16]" label

# wei -> RITUAL string, truncated to 6 decimals. String-only (no printf %f), so it stays correct
# regardless of the locale's decimal separator; cast always emits a '.'-separated value.
fmt_rit() {
  local v int frac
  v="$(cast to-unit "${1:-0}" ether)"
  int="${v%%.*}"; frac="${v#*.}"
  [ "$int" = "$v" ] && frac=""
  frac="${frac}000000"
  printf '%s.%s' "$int" "${frac:0:6}"
}

# Run a read-only cast call, retrying on an empty result (the public RPC can be flaky). Always
# exits 0 with the value or "", so callers never abort under set -e on a transient error.
rpc_read() {
  local i out=""
  for i in 1 2 3; do
    out="$("$@" 2>/dev/null)" && [ -n "$out" ] && break
    sleep 1
  done
  printf '%s' "$out"
}
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
predict_harness() { rpc_read cast call "$FACTORY" "predictHarness(address,bytes32)(address,bytes32)" "$WALLET_ADDRESS" "$1" --rpc-url "$RPC_URL" | head -1; }
deployed() { local c; c="$(rpc_read cast code "$HARNESS" --rpc-url "$RPC_URL")"; [ "${#c}" -gt 2 ]; }

# Alive = the Scheduler still holds a scheduled wake for this agent. The Scheduler's calls(callId)
# reverts once a call is gone, so a non-empty read on the agent's current or next callId means it is
# still armed. A dead agent has no callId left and cannot be revived, so a deposit would just be stuck.
agent_alive() {
  local h="$1" w out getter
  for getter in 0x618abb34 0x61f32724; do
    w="$(rpc_read cast call "$h" "$getter" --rpc-url "$RPC_URL")"; w="${w#0x}"
    { [ -z "$w" ] || [ -z "${w//0/}" ]; } && continue
    out="$(rpc_read cast call "$SCHEDULER" "0xd183ce14$w" --rpc-url "$RPC_URL")"
    [ -n "$out" ] && return 0
  done
  return 1
}

### ---------- keystore signer ----------
KEYSTORE_DIR="$HOME/.foundry/keystores"
# Honor a KS_PASSWORD passed via the environment so the script can run without a
# terminal (e.g. in a cloud sandbox with no /dev/tty); empty means prompt as before.
KS_PASSWORD="${KS_PASSWORD:-}"

# Read a secret showing one '*' per char (backspace supported) into REPLY_SECRET.
read_masked() {
  local ch p=""; printf '%s' "$1" >&2
  while IFS= read -rsn1 ch < /dev/tty; do
    [ -z "$ch" ] && break
    if [ "$ch" = $'\177' ] || [ "$ch" = $'\b' ]; then
      [ -n "$p" ] && { p="${p%?}"; printf '\b \b' >&2; }
    else p="$p$ch"; printf '*' >&2; fi
  done
  printf '\n' >&2; REPLY_SECRET="$p"
}

# Set or replace KEY=VALUE in .env so the name and address persist across runs.
set_env_var() {
  local k="$1" v="$2" f="$HERE/.env" tmp
  if grep -q "^$k=" "$f" 2>/dev/null; then
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "$k="*) printf '%s=%s\n' "$k" "$v" ;; *) printf '%s\n' "${line%$'\r'}" ;; esac
    done < "$f" > "$tmp"
    mv "$tmp" "$f"
  else printf '%s=%s\n' "$k" "$v" >> "$f"; fi
}

# First run: ask name + key + password, create the encrypted keystore, save name + address.
import_keystore() {
  banner
  step "Set up your wallet keystore"
  local name="${KEYSTORE_ACCOUNT:-}" key p1 p2 i
  if [ -z "$name" ]; then
    printf '  %sname for your keystore [ritual-deployer]:%s ' "$ACCENT" "$RESET" >&2
    IFS= read -r name < /dev/tty || name=""; name="${name%$'\r'}"; [ -z "$name" ] && name="ritual-deployer"
  fi
  if [ -f "$KEYSTORE_DIR/$name" ]; then          # name already exists -> adopt it, don't re-import
    KEYSTORE_ACCOUNT="$name"; set_env_var KEYSTORE_ACCOUNT "$name"
    unlock
    WALLET_ADDRESS="$(cast wallet address --account "$name" --password "$KS_PASSWORD" 2>/dev/null)" || fail "wrong keystore password"
    set_env_var WALLET_ADDRESS "$WALLET_ADDRESS"
    ok "using existing keystore '$name' for $WALLET_ADDRESS"; return
  fi
  # PRIVATE_KEY / KS_PASSWORD from the environment skip the /dev/tty prompts, for
  # sandboxes with no terminal. The key still only goes to `cast wallet import` below.
  key="${PRIVATE_KEY:-}"
  if [ -z "$key" ]; then read_masked "  paste your wallet private key: "; key="$REPLY_SECRET"; fi
  [ -n "$key" ] || fail "no private key entered"
  case "$key" in 0x*) ;; *) key="0x$key" ;; esac
  if [ -n "$KS_PASSWORD" ]; then
    p1="$KS_PASSWORD"
  else
    for i in 1 2 3; do
      read_masked "  set a keystore password: "; p1="$REPLY_SECRET"
      read_masked "  confirm password: ";        p2="$REPLY_SECRET"
      [ -n "$p1" ] && [ "$p1" = "$p2" ] && break
      { [ -z "$p1" ] && warn "empty password ($i/3)"; } || warn "passwords do not match ($i/3)"
      p1=""
    done
  fi
  [ -n "$p1" ] || fail "could not set a password after 3 tries"
  spin "creating encrypted keystore" cast wallet import "$name" --private-key "$key" --unsafe-password "$p1"
  WALLET_ADDRESS="$(cast wallet address --private-key "$key" 2>/dev/null)" || fail "invalid private key"
  key=""; KEYSTORE_ACCOUNT="$name"; KS_PASSWORD="$p1"
  set_env_var KEYSTORE_ACCOUNT "$name"
  set_env_var WALLET_ADDRESS "$WALLET_ADDRESS"
  ok "keystore '$name' ready for $WALLET_ADDRESS"
}

# Ensure a keystore + public address exist (import on first run). Reads never need the password.
resolve_signer() {
  local name="${KEYSTORE_ACCOUNT:-}"
  if [ -z "$name" ] || [ ! -f "$KEYSTORE_DIR/$name" ]; then import_keystore; return; fi
  KEYSTORE_ACCOUNT="$name"
  if [ -z "${WALLET_ADDRESS:-}" ]; then
    unlock
    WALLET_ADDRESS="$(cast wallet address --account "$name" --password "$KS_PASSWORD" 2>/dev/null)" || fail "wrong keystore password"
    set_env_var WALLET_ADDRESS "$WALLET_ADDRESS"
  fi
}

# Ask the keystore password once per run (masked), retrying up to 3 times if it is wrong.
unlock() {
  [ -n "$KS_PASSWORD" ] && return 0
  local i pw
  for i in 1 2 3; do
    read_masked "  keystore password: "; pw="$REPLY_SECRET"
    if cast wallet address --account "$KEYSTORE_ACCOUNT" --password "$pw" >/dev/null 2>&1; then
      KS_PASSWORD="$pw"; return 0
    fi
    warn "wrong password ($i/3)"
  done
  fail "wrong keystore password after 3 tries"
}

# Next salt for a fresh agent: bump a trailing number, else append -2 (agent-1 -> agent-2).
next_salt() {
  local s="$1"
  if [[ "$s" =~ ^(.*[^0-9])([0-9]+)$ ]]; then printf '%s%s' "${BASH_REMATCH[1]}" "$(( BASH_REMATCH[2] + 1 ))"
  elif [[ "$s" =~ ^([0-9]+)$ ]]; then printf '%s' "$(( s + 1 ))"
  else printf '%s-2' "$s"; fi
}

# Fixed gas for configureFundAndStart. Ritual's estimateGas lies here (~192M for a call that really
# uses ~2.1M), so we ignore it - a real deploy went through on 3.5M. 5M leaves room and stays
# well under the 200M block limit. The cast call below still catches a genuinely bad request.
SCHED_GAS=5000000

### ---------- prerequisites (auto-install, no prompts) ----------
# Foundry lands in ~/.foundry/bin, uv in ~/.local/bin. Put both on PATH for this run...
ensure_path_now() {
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac
  case ":$PATH:" in *":$HOME/.foundry/bin:"*) ;; *) PATH="$HOME/.foundry/bin:$PATH";; esac
  export PATH
}
# ...and once in ~/.bashrc so future shells see it too (idempotent, marker-guarded).
persist_path() {
  local dir="$1" rc="$HOME/.bashrc"
  [ -f "$rc" ] || : >"$rc"
  grep -qF "ritual-path:$dir" "$rc" 2>/dev/null && return 0
  printf '\n# ritual-path:%s\nexport PATH="%s:$PATH"\n' "$dir" "$dir" >>"$rc"
}

# Make sure curl is available (the foundry + uv installers need it). Auto-install via the system
# package manager when missing; Git Bash and macOS already ship it.
ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  step "Installing curl"
  info "this may ask for your sudo password"
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y curl
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y curl
  elif command -v yum     >/dev/null 2>&1; then sudo yum install -y curl
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm curl
  elif command -v zypper  >/dev/null 2>&1; then sudo zypper --non-interactive install curl
  elif command -v apk     >/dev/null 2>&1; then sudo apk add curl
  elif command -v brew    >/dev/null 2>&1; then brew install curl
  else fail "curl is missing and no known package manager was found - install curl, then re-run"
  fi || true
  command -v curl >/dev/null 2>&1 || fail "could not install curl automatically - install it manually, then re-run"
}

install_foundry() {
  step "Installing Foundry (cast, forge)"
  ensure_curl
  spin 3 "fetch foundryup"      bash -c 'curl -fsSL https://foundry.paradigm.xyz | bash'
  ensure_path_now
  spin 3 "install cast + forge" "$HOME/.foundry/bin/foundryup"
  persist_path "$HOME/.foundry/bin"
}

install_uv() {
  step "Installing uv"
  ensure_curl
  # Pin UV_INSTALL_DIR so uv lands exactly where ensure_path_now / persist_path add it to PATH. The
  # installer defaults there too, but pinning makes the two halves provably agree. $HOME is expanded
  # by the inner bash at run time (kept literal through the single quotes), so it is always set.
  spin 3 "fetch + install uv" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$HOME/.local/bin" sh'
  ensure_path_now
  persist_path "$HOME/.local/bin"
}

ensure_tools() {
  ensure_path_now
  { command -v cast >/dev/null 2>&1 && command -v forge >/dev/null 2>&1; } || install_foundry
  command -v uv >/dev/null 2>&1 || install_uv
  ensure_path_now
  local miss=
  for bin in cast forge uv; do command -v "$bin" >/dev/null 2>&1 || miss="$miss $bin"; done
  [ -z "$miss" ] || fail "still missing after install:$miss - open a new shell and retry"
}

# install tools, then ensure a keystore + public address exist (imports your wallet on first run)
ensure_tools
resolve_signer

# DEPOSIT is given in whole RITUAL (DEPOSIT=1 -> 1 RITUAL, decimals like 0.5 ok). Convert to wei once
# cast is on PATH; everything downstream (min-check, deploy, value flags) works in wei.
if [ -n "${DEPOSIT:-}" ]; then
  DEPOSIT_WEI="$(cast to-wei "$DEPOSIT" ether 2>/dev/null)" \
    || fail "DEPOSIT=$DEPOSIT is not a valid RITUAL amount (use a number like 1 or 0.5)"
fi

# deterministic harness address (also the delivery target) - needed by every command
USERSALT="$(cast keccak "${SALT:-ritual-agent-1}")"
HARNESS="$(predict_harness "$USERSALT")"
export HARNESS

# Live = a contract is deployed at this harness AND it has already been configured.
is_live() {
  local h="$1" c
  c="$(rpc_read cast code "$h" --rpc-url "$RPC_URL")"
  [ "${#c}" -le 2 ] && return 1
  [ "$(rpc_read cast call "$h" 'configured()(bool)' --rpc-url "$RPC_URL")" = "true" ]
}

# view [eoa] -> show every sovereign agent an EOA deployed (from the chain indexer, not by guessing
# salts): each LIVE or DEAD with the RITUAL stuck in its wallet, in a table. No address -> your wallet.
cmd_view() {
  local eoa="${1:-$WALLET_ADDRESS}"
  is_addr "$eoa" || fail "not a valid EOA address: $eoa"
  banner
  kv "Owner" "$eoa"
  kv "Chain" "$(cast chain-id --rpc-url "$RPC_URL")"
  scan_agents "$eoa"
  if [ "${SCAN_LIVE:-0}" -gt 0 ]; then
    info "add funds to a live agent: bash run.sh topup <agent-address> [amount]  (in RITUAL)"
  elif [ "${SCAN_DEAD:-0}" -gt 0 ]; then
    info "dead agents cannot be revived and their balance is stuck; start fresh with: bash run.sh deploy"
  fi
}

# Run the embedded indexer scanner for an EOA and print the LIVE/DEAD + stuck-RITUAL table. Sets
# SCAN_COUNT / SCAN_LIVE / SCAN_DEAD / SCAN_TOTAL / SCAN_N for the caller. Stdlib-only Python under uv.
scan_agents() {
  local eoa="$1"
  step "Scanning agents"
  info "reading the indexer + chain - can take ~10-30s for busy wallets"

  local PYTMP; PYTMP="$(mktemp)"
  cat >"$PYTMP" <<'PY'
import json, os, sys, urllib.request, urllib.error, datetime
RPC     = os.environ.get("RPC_URL", "https://rpc.ritualfoundation.org")
INDEXER = "https://explorer.ritualfoundation.org/api/indexer-proxy/api/v1"
FACTORY = "0x9dc4c054e53bcc4ce0a0ff09e890a7a8e817f304"
WALLET  = "0x532f0df0896f353d8c3dd8cc134e8129da2a3948"
SCHED   = "0x56e776bae2dd60664b69bd5f865f1180ffb7d58b"
SEL = {"wakeMode":"0x60db537d","configured":"0x8772a23a","currentSeriesId":"0xc9777451",
       "curCallId":"0x618abb34","nextCallId":"0x61f32724","balanceOf":"0x70a08231",
       "lockUntil":"0xeba74ee9","calls":"0xd183ce14","predictHarness":"0x78165f40"}
DEPLOY_SEL, CONFIG_SEL = "0x3293993b", "0xb1906702"
UA = "Mozilla/5.0 (RitualAgentExplorer)"
def _post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"content-type":"application/json","user-agent":UA})
    with urllib.request.urlopen(req, timeout=40) as r: return json.loads(r.read())
def _get(url):
    req = urllib.request.Request(url, headers={"accept":"application/json","user-agent":UA})
    try:
        with urllib.request.urlopen(req, timeout=40) as r: return json.loads(r.read()), 200
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read()), e.code
        except Exception: return None, e.code
    except Exception: return None, 0
def rpc(method, params):
    try: return _post(RPC, {"jsonrpc":"2.0","method":method,"params":params,"id":1}).get("result")
    except Exception: return None
def rpc_batch(reqs):
    body = [{"jsonrpc":"2.0","method":m,"params":p,"id":i} for i,(m,p) in enumerate(reqs)]
    out = [None]*len(reqs)
    try:
        for item in _post(RPC, body):
            if isinstance(item, dict) and "id" in item: out[item["id"]] = item.get("result")
    except Exception:
        for i,(m,p) in enumerate(reqs): out[i] = rpc(m,p)
    return out
def eth_call(to, data): return rpc("eth_call", [{"to":to,"data":data}, "latest"])
def pad(a): return a.lower().replace("0x","").rjust(64,"0")
def hint(h):
    if not h or h == "0x": return 0
    try: return int(h, 16)
    except Exception: return 0
def word_addr(res):
    if not res or len(res) < 66: return None
    return "0x" + res[2:][24:64]
def predict_harness(owner, salt32):
    return word_addr(eth_call(FACTORY, SEL["predictHarness"]+pad(owner)+salt32.replace("0x","").rjust(64,"0")))
def indexer_txs(eoa):
    eoa = eoa.lower(); txs = {}
    d, code = _get(f"{INDEXER}/addresses/{eoa}/transactions?limit=100")
    if code == 200 and d and "transactions" in d:
        for t in d["transactions"]: txs[t["tx_hash"]] = t
        off = 100
        while d.get("hasMore") and off < 1000:
            d, code = _get(f"{INDEXER}/addresses/{eoa}/transactions?limit=100&offset={off}")
            if not d or "transactions" not in d: break
            for t in d["transactions"]: txs[t["tx_hash"]] = t
            off += 100
        return list(txs.values())
    cur = datetime.date.today()
    for _ in range(24):
        start = cur.replace(day=1); fd, td = start.isoformat(), cur.isoformat(); off = 0
        while True:
            d, code = _get(f"{INDEXER}/addresses/{eoa}/transactions?limit=50&offset={off}&from_date={fd}&to_date={td}")
            if not d or "transactions" not in d: break
            for t in d["transactions"]: txs[t["tx_hash"]] = t
            if not d.get("hasMore"): break
            off += 50
        cur = start - datetime.timedelta(days=1)
    return list(txs.values())
def find_agents(txs, eoa):
    eoa = eoa.lower(); agents = {}
    for t in txs:
        if (t.get("from_address") or "").lower() != eoa: continue
        sel = (t.get("method_selector") or "")[:10]
        if sel == CONFIG_SEL:
            a = (t.get("to_address") or "").lower()
            if a: agents.setdefault(a, {}); agents[a]["configured"]=True
        elif sel == DEPLOY_SEL:
            inp = t.get("input_data")
            if not inp:
                td, _ = _get(f"{INDEXER}/transactions/{t['tx_hash']}"); inp = (td or {}).get("input_data")
            if inp and len(inp) >= 74:
                a = predict_harness(eoa, "0x"+inp[10:74])
                if a: a=a.lower(); agents.setdefault(a, {}); agents[a]["salt"]="0x"+inp[10:74]
    return agents
def agent_status(addr, block):
    addr = addr.lower()
    r = rpc_batch([
        ("eth_call",[{"to":addr,"data":SEL["wakeMode"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["configured"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["currentSeriesId"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["curCallId"]},"latest"]),
        ("eth_call",[{"to":addr,"data":SEL["nextCallId"]},"latest"]),
        ("eth_call",[{"to":WALLET,"data":SEL["balanceOf"]+pad(addr)},"latest"]),
        ("eth_call",[{"to":WALLET,"data":SEL["lockUntil"]+pad(addr)},"latest"]),
    ])
    c1, c4 = hint(r[3]), hint(r[4]); scheduled=False
    for cid in (c1, c4):
        if cid and eth_call(SCHED, SEL["calls"]+hex(cid)[2:].rjust(64,"0")) is not None:
            scheduled=True; break
    lock = hint(r[6])
    return {"wakeMode":hint(r[0]),"configured":hint(r[1])==1,"series":hint(r[2]),
            "balance_wei":hint(r[5]),"lockUntil":lock,"lockExpired":(block>=lock if lock else True),
            "live":scheduled}
def main():
    eoa = (sys.argv[1] if len(sys.argv)>1 else os.environ.get("WALLET_ADDRESS","")).strip()
    block = hint(rpc("eth_blockNumber", []))
    txs = indexer_txs(eoa); amap = find_agents(txs, eoa); rows = []
    for a, meta in amap.items():
        try:
            st = agent_status(a, block); st.update(meta); st["address"]=a; rows.append(st)
        except Exception as e:
            rows.append({"address":a,"error":str(e),"balance_wei":0})
    rows.sort(key=lambda x: x.get("series",0), reverse=True)
    live = sum(1 for x in rows if x.get("live")); total = sum(int(x.get("balance_wei",0)) for x in rows)
    print(f"BLOCK={block}")
    for x in rows:
        print("AGENT\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s" % (
            x["address"], 1 if x.get("live") else 0, 1 if x.get("configured") else 0,
            x.get("wakeMode",0), x.get("series",0), int(x.get("balance_wei",0)),
            x.get("lockUntil",0), 1 if x.get("lockExpired") else 0, x.get("salt","") or ""))
    print("SUMMARY\t%d\t%d\t%d\t%d" % (len(rows), live, len(rows)-live, total))
if __name__ == "__main__":
    main()
PY
  # `python` (not python3): uv's managed interpreter exposes `python` on every platform, incl. the
  # Windows uv env used under Git Bash, where a bare `python3` falls through to the MS Store stub.
  spin 3 "discover agents, check live/dead, read balances" \
    uv run --quiet --python 3.12 python "$PYTMP" "$eoa"
  rm -f "$PYTMP"

  SCAN_COUNT=0; SCAN_LIVE=0; SCAN_DEAD=0; SCAN_TOTAL=0; SCAN_N=0
  local sline
  sline="$(grep -E '^SUMMARY' "$LOGFILE" | tail -1)"
  if [ -n "$sline" ]; then IFS=$'\t' read -r _ SCAN_COUNT SCAN_LIVE SCAN_DEAD SCAN_TOTAL <<< "$sline"; fi

  step "Your agents"
  while IFS=$'\t' read -r _ addr islive cfg wake series bal lock lockexp salt; do
    [ -z "$addr" ] && continue
    if [ "$SCAN_N" -eq 0 ]; then                     # header row, printed once above the first agent
      printf '  %s%-42s  %-4s  %12s  %6s  %-12s  %s%s\n' \
        "$MUTED" "AGENT" "STATE" "RITUAL" "SERIES" "CONFIG" "LOCK" "$RESET"
    fi
    SCAN_N=$((SCAN_N + 1))
    local statec statew lockstr cfgstr
    if [ "$islive" = 1 ]; then statec="$OKC"; statew="live"; else statec="$BADC"; statew="dead"; fi
    if [ "$lockexp" = 1 ]; then lockstr="unlocked"; else lockstr="locked @ $lock"; fi
    if [ "$cfg" = 1 ]; then cfgstr="configured"; else cfgstr="unconfigured"; fi
    printf '  %s%-42s%s  %s%-4s%s  %12s  %6s  %-12s  %s\n' \
      "$BOLD" "$addr" "$RESET" "$statec" "$statew" "$RESET" "$(fmt_rit "$bal")" "$series" "$cfgstr" "$lockstr"
  done < <(grep -E '^AGENT' "$LOGFILE")

  if [ "$SCAN_N" -eq 0 ]; then
    info "no sovereign agents found for this EOA"
  else
    hr
    kv "Agents" "$SCAN_COUNT  (${OKC}${SCAN_LIVE} live${RESET} / ${BADC}${SCAN_DEAD} dead${RESET})"
    kv "Stuck RITUAL" "$(fmt_rit "${SCAN_TOTAL:-0}") across all agents"
  fi
}

cmd_topup() {
  local ritual amount
  if is_addr "${1:-}"; then HARNESS="$1"; ritual="${2:-${DEPOSIT:-}}"; else ritual="${1:-${DEPOSIT:-}}"; fi
  [ -n "$ritual" ] || fail "amount required: bash run.sh topup <address> <amount>  (in RITUAL, or set DEPOSIT in .env)"
  amount="$(cast to-wei "$ritual" ether 2>/dev/null)" || fail "amount '$ritual' is not a valid RITUAL number"
  deployed || fail "harness not deployed yet - run: bash run.sh deploy"
  agent_alive "$HARNESS" || fail "agent $HARNESS is dead - it has no scheduled wake left, so a deposit cannot revive it and would be stuck. Deploy a fresh agent: bash run.sh deploy"
  banner
  step "Deposit $ritual RITUAL"
  kv "agent" "$HARNESS"
  info "lock $LOCK_BLOCKS blocks"
  unlock
  spin "depositing" \
    cast send "$RITUAL_WALLET" "depositFor(address,uint256)" "$HARNESS" "$LOCK_BLOCKS" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --value "$amount"
  ok "topped up. balance $(cast to-unit "$(num "$(rpc_read cast call "$RITUAL_WALLET" 'balanceOf(address)(uint256)' "$HARNESS" --rpc-url "$RPC_URL")")" ether) RITUAL"
  info "this deposit funds the agent's upcoming wakes"
}

cmd_deploy() {
  need_deposit
  require_min_deposit
  banner
  kv "Owner" "$WALLET_ADDRESS"
  kv "Chain" "$(cast chain-id --rpc-url "$RPC_URL")"
  kv "Balance" "$(cast balance "$WALLET_ADDRESS" --ether --rpc-url "$RPC_URL") RITUAL"

  # Resolve the agent address for SALT. If that slot already has a live agent, show the wallet's full
  # fleet from the indexer (the same table as `view`), then ask before bumping to the next free salt
  # (my-agent-1 -> my-agent-2 -> ...) and deploying there.
  step "Select agent"
  local salt="${SALT:-ritual-agent-1}" reply n=0
  USERSALT="$(cast keccak "$salt")"
  HARNESS="$(predict_harness "$USERSALT")"
  if is_live "$HARNESS"; then
    scan_agents "$WALLET_ADDRESS"
    printf '\n  %sDeploy another (new) agent? [y/N]%s ' "$ACCENT" "$RESET"
    read -r reply < /dev/tty 2>/dev/null || reply=""; reply="${reply%$'\r'}"
    case "$reply" in
      y|Y|yes|YES) ;;
      *) printf '\n'; info "left it running - inspect with: bash run.sh view"; exit 0 ;;
    esac
    while is_live "$HARNESS"; do
      salt="$(next_salt "$salt")"
      USERSALT="$(cast keccak "$salt")"
      HARNESS="$(predict_harness "$USERSALT")"
      n=$((n + 1)); [ "$n" -gt 200 ] && fail "200+ live agents - set a fresh SALT in .env"
    done
    ok "new slot: $salt"
  fi
  export HARNESS
  kv "Salt" "$salt"
  kv "Deposit" "$DEPOSIT RITUAL"
  kv "Harness" "$HARNESS"
  unlock

  # build the encrypted, ABI-encoded configureFundAndStart payload
  step "Build request"
  local PYTMP; PYTMP="$(mktemp)"
  cat >"$PYTMP" <<'PY'
import os
from ecies import encrypt as ecies_encrypt
from ecies.config import ECIES_CONFIG
from eth_abi.abi import encode
from web3 import Web3

ECIES_CONFIG.symmetric_nonce_length = 12
w3 = Web3(Web3.HTTPProvider(os.environ["RPC_URL"]))
reg_abi = [{"name": "getServicesByCapability", "type": "function", "stateMutability": "view",
            "inputs": [{"name": "c", "type": "uint8"}, {"name": "v", "type": "bool"}],
            "outputs": [{"name": "", "type": "tuple[]", "components": [
                {"name": "node", "type": "tuple", "components": [
                    {"name": "paymentAddress", "type": "address"}, {"name": "teeAddress", "type": "address"},
                    {"name": "teeType", "type": "uint8"}, {"name": "publicKey", "type": "bytes"},
                    {"name": "endpoint", "type": "string"}, {"name": "certPubKeyHash", "type": "bytes32"},
                    {"name": "capability", "type": "uint8"}]},
                {"name": "isValid", "type": "bool"}, {"name": "workloadId", "type": "bytes32"}]}]}]
reg = w3.eth.contract(address=Web3.to_checksum_address(os.environ["REGISTRY"]), abi=reg_abi)
svc = reg.functions.getServicesByCapability(0, True).call()
if not svc:
    raise SystemExit("no valid executors in TEEServiceRegistry")
node = svc[0][0]
executor = Web3.to_checksum_address(node[1])
pub = bytes(node[3])

harness = Web3.to_checksum_address(os.environ["HARNESS"])
enc = ecies_encrypt(pub.hex(), b'{"LLM_PROVIDER":"ritual"}')
delivery_selector = Web3.keccak(text="onSovereignAgentResult(bytes32,bytes)")[:4]
# maxPollBlock is a Phase-2 deadline OFFSET (relative to settlement), not an absolute block.
# The chain rejects the agent's async job unless ttl < maxPollBlock <= 70000; 6000 ~= 35 min.
max_poll_block = 6000

params = (
    executor, 500, b"", 5, max_poll_block, "SOVEREIGN_AGENT_TASK", harness, delivery_selector,
    3_000_000, 1_000_000_000, 100_000_000, int(os.environ["CLI_TYPE"]), os.environ["PROMPT"], enc,
    ("", "", ""), ("", "", ""), [], ("", "", ""), os.environ["MODEL"], [], 50, 8192, "",
)
# frequency 2000 blocks (~11.7 min) clears the 60-90s agent round-trip so a new wake does not
# hit the per-sender async lock; windowNumCalls 5 keeps 5*2000 within MAX_LIFESPAN (10000).
schedule = (800_000, 2000, 500, 1_000_000_000, 100_000_000, 0)
rolling = (5, 5000, 1)

PT = ("(address,uint256,bytes,uint64,uint64,string,address,bytes4,uint256,uint256,uint256,uint16,"
      "string,bytes,(string,string,string),(string,string,string),(string,string,string)[],"
      "(string,string,string),string,string[],uint16,uint32,string)")
ST = "(uint32,uint32,uint32,uint256,uint256,uint256)"
RT = "(uint32,uint16,uint16)"
selector = Web3.keccak(text=f"configureFundAndStart({PT},{ST},{RT},uint256)")[:4]
data = selector + encode([PT, ST, RT, "uint256"], [params, schedule, rolling, int(os.environ["LOCK_BLOCKS"])])
print("EXECUTOR=" + executor)
print("CONFIG_CALLDATA=0x" + data.hex())
PY
  # Pin Python 3.12 + eciespy 0.4: coincurve (eciespy's secp256k1 dep) ships wheels only to cp313 so
  # 3.14+ builds from source and fails, and eciespy's config/encrypt API changed at 0.3 -> 0.4. Use
  # `python` not `python3` so it also works in uv's Windows env under Git Bash. uv fetches 3.12 itself.
  spin 3 "discover executor, encrypt secret, encode calldata" \
    uv run --quiet --python 3.12 --with 'eciespy>=0.4,<0.5' --with eth-abi --with web3 python "$PYTMP"
  rm -f "$PYTMP"
  local OUT EXECUTOR CONFIG_CALLDATA
  OUT="$(cat "$LOGFILE")"
  EXECUTOR="$(printf '%s\n' "$OUT" | awk -F= '$1=="EXECUTOR"{print $2}')"
  CONFIG_CALLDATA="$(printf '%s\n' "$OUT" | awk -F= '$1=="CONFIG_CALLDATA"{print $2}')"
  [ -n "$CONFIG_CALLDATA" ] || { printf '%s\n' "$OUT"; fail "failed to build request"; }
  ok "executor $EXECUTOR"

  # deploy the harness if it is not on-chain yet (CREATE3 needs ~2.5M gas)
  step "Deploy harness"
  local CODE; CODE="$(rpc_read cast code "$HARNESS" --rpc-url "$RPC_URL")"
  if [ "${#CODE}" -le 2 ]; then
    spin "deploying harness" \
      cast send "$FACTORY" "deployHarness(bytes32)" "$USERSALT" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --gas-limit 3500000
    ok "harness deployed"
  else
    ok "already on-chain - skipping"
  fi

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    CODE="$(cast code "$HARNESS" --rpc-url "$RPC_URL" 2>/dev/null || true)"
    [ "${#CODE}" -gt 2 ] && break
  done
  [ "${#CODE}" -gt 2 ] || fail "harness has no code after deploy"

  # verify, simulate (no spend), then fund + arm
  step "Fund and arm"
  spin 3 "simulate configureFundAndStart (no spend)" \
    cast call "$HARNESS" "$CONFIG_CALLDATA" --from "$WALLET_ADDRESS" --value "$DEPOSIT_WEI" --rpc-url "$RPC_URL"
  spin "fund and arm (configureFundAndStart)" \
    cast send "$HARNESS" "$CONFIG_CALLDATA" --account "$KEYSTORE_ACCOUNT" --password "$KS_PASSWORD" --rpc-url "$RPC_URL" --value "$DEPOSIT_WEI" --gas-limit "$SCHED_GAS"
  ok "funded and armed"

  printf '\n'; hr
  printf '  %sCongratulations - your sovereign agent is live!%s\n\n' "${BOLD}${OKC}" "$RESET"
  printf '  %sYour sovereign agent contract address:%s\n' "$MUTED" "$RESET"
  printf '  %s%s%s\n\n' "${BOLD}${ACCENT}" "$HARNESS" "$RESET"
  kv "configured" "$(rpc_read cast call "$HARNESS" 'configured()(bool)' --rpc-url "$RPC_URL")"
  kv "wakeMode" "$(num "$(rpc_read cast call "$HARNESS" 'wakeMode()(uint8)' --rpc-url "$RPC_URL")")  (1 armed)"
  hr
}

case "$CMD" in
  deploy)         cmd_deploy ;;
  view|status)    cmd_view "${1:-}" ;;
  topup|fund)     cmd_topup "${1:-}" "${2:-}" ;;
  *)              usage; fail "unknown command: $CMD" ;;
esac
