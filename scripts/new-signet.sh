#!/usr/bin/env bash
#
# Bootstrap a new signet. Uses the SAME drivechaind image as the mainchain
# service so the wallet file is byte-format compatible with the production node.
#
# Bitcoin Core stamps a wallet's SQLite application_id with the network magic, so
# a wallet only loads on a node running the matching -signetchallenge. The
# challenge is itself derived from the wallet, so this runs in two phases:
#   phase 1: default signet -> create a wallet, learn its challenge + magic
#   phase 2: a node running THAT challenge -> rebuild the wallet (import the key)
#            so its application_id matches the new network's magic
# The phase-2 wallet file is the artifact; SIGNET_CHALLENGE / NETWORK_MAGIC /
# SIGNET_MINER_COINBASE_RECIPIENT are written to env.signet.
#
# To deploy onto the mainchain node (it signs the blocks):
#   1. copy all four values from <out>/env.signet into .env.signet (SIGNET_VERSION
#      drives the compose project name, so a new version = a fresh data volume).
#   2. just bootstrap-signet <out>
#      (starts mainchain on the new challenge, loads the wallet, brings up the stack)
set -euo pipefail

usage() {
  echo "usage: scripts/new-signet.sh [OUTPUT_DIR]"
}

# Network magic = first 4 bytes of dSHA256(CompactSize(len) || challenge).
magic_from_challenge() {
  local challenge="$1" len cs
  len=$(( ${#challenge} / 2 ))
  cs=$(printf '%02x' "$len")
  printf '%s' "${cs}${challenge}" \
    | xxd -r -p \
    | sha256sum | cut -d' ' -f1 | xxd -r -p \
    | sha256sum | cut -d' ' -f1 | cut -c1-8
}

OUT=""
WALLET="signet-miner"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

missing=()
for bin in docker jq xxd sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
[[ ${#missing[@]} -eq 0 ]] || { echo "error: missing required binaries: ${missing[*]}" >&2; exit 1; }

# Digits only: also used as SIGNET_VERSION -> the compose project name.
version="$(date -u +%Y%m%d%H%M%S)"
[[ -n "$OUT" ]] || OUT="signet-$version"
[[ ! -e "$OUT" ]] || { echo "error: output path already exists: $OUT" >&2; exit 1; }

# Pin to the same node image the mainchain service uses, so wallet files match.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="$(grep -m1 -E '^[[:space:]]*image:[[:space:]]*ghcr.io/layertwo-labs/bitcoin-patched' \
  "$repo_root/docker-compose.base.yml" | awk '{print $2}')"
[[ -n "$image" ]] || { echo "error: bitcoin-patched image not found in docker-compose.base.yml" >&2; exit 1; }

datadir=/home/drivechain/.drivechain
C1="signet-gen1-$$"
C2="signet-gen2-$$"
trap 'docker rm -f "$C1" "$C2" >/dev/null 2>&1 || true' EXIT

# Start an offline node (no peers, no sync) and wait for RPC. $1=name, rest=extra args.
start_node() {
  local name="$1"; shift
  docker run -d --name "$name" "$image" \
    drivechaind -signet "-datadir=$datadir" -connect=0 -listen=0 -dnsseed=0 "$@" >/dev/null
  local i
  for i in $(seq 1 120); do
    docker exec "$name" drivechain-cli -signet "-datadir=$datadir" getblockchaininfo >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  echo "error: node $name did not become ready" >&2
  docker logs --tail 20 "$name" >&2
  return 1
}

# --- phase 1: default signet, learn the challenge and grab the key ---
start_node "$C1"
G1=(docker exec "$C1" drivechain-cli -signet "-datadir=$datadir" -rpcwallet=gen)
docker exec "$C1" drivechain-cli -signet "-datadir=$datadir" -named createwallet wallet_name=gen >/dev/null
challenge_addr="$("${G1[@]}" getnewaddress signet-challenge)"
challenge="$("${G1[@]}" getaddressinfo "$challenge_addr" | jq -r .scriptPubKey)"
coinbase_addr="$("${G1[@]}" getnewaddress miner-payout)"
descriptors="$("${G1[@]}" listdescriptors true \
  | jq -c '[.descriptors[] | {desc, active, internal, range, timestamp:"now"} | with_entries(select(.value != null))]')"
magic="$(magic_from_challenge "$challenge")"
docker rm -f "$C1" >/dev/null 2>&1

# --- phase 2: a node running THIS challenge, so the wallet's app_id matches ---
start_node "$C2" -signetchallenge="$challenge"
G2=(docker exec "$C2" drivechain-cli -signet "-datadir=$datadir" -rpcwallet="$WALLET")
docker exec "$C2" drivechain-cli -signet "-datadir=$datadir" \
  -named createwallet wallet_name="$WALLET" blank=true >/dev/null
imported="$("${G2[@]}" importdescriptors "$descriptors")"
echo "$imported" | jq -e 'all(.[]; .success)' >/dev/null \
  || { echo "error: importdescriptors failed: $imported" >&2; exit 1; }

# Shut down so the wallet db is flushed, then copy it out of the container.
"${G2[@]}" stop >/dev/null
docker wait "$C2" >/dev/null

mkdir -p "$OUT"
WALLET_FILE="$OUT/$WALLET.dat"
docker cp "$C2:$datadir/signet/wallets/$WALLET/wallet.dat" "$WALLET_FILE" >/dev/null
echo "wrote wallet: $WALLET_FILE" >&2

printf 'SIGNET_VERSION=%s\nSIGNET_MINER_COINBASE_RECIPIENT=%s\nSIGNET_CHALLENGE=%s\nNETWORK_MAGIC=%s\n' \
  "$version" "$coinbase_addr" "$challenge" "$magic" > "$OUT/env.signet"
echo "wrote network params: $OUT/env.signet" >&2
