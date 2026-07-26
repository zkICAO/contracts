#!/usr/bin/env bash
# Deploys and registers on a chain, the way a deployment would.
#
# Points at a local devnet by default because that needs nobody's funds and
# nobody's key, and the EVM it runs is the same EVM. Point RPC_URL and
# PRIVATE_KEY elsewhere and the same script runs against a testnet: nothing
# here is devnet specific.
#
# What it proves that a forge test cannot: that the deploy script works, that
# the contracts fit and deploy, that a transaction carrying an eighteen
# kilobyte proof is accepted by a node, and what it costs in a real block.
#
# The proofs must be bound to the sender, since the contract takes the sender
# as the context, so the bundle is proved with that address:
#
#   ZKICAO_CONTEXT=$(python3 -c "print(int('<sender>', 16))") \
#     cargo run -- bundle
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rpc="${RPC_URL:-http://127.0.0.1:8545}"

# Anvil's first account. Override for anywhere real.
key="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

fixtures="$here/test/fixtures"

sender=$(cast wallet address --private-key "$key")

echo "sender $sender"

# The policy comes from the proofs, which is where a deployment's own
# registry build would put it.
export ZKICAO_DOMAIN=$(python3 -c "
raw = open('$fixtures/registration.inputs','rb').read(); print('0x' + raw[0:32].hex())")

export ZKICAO_REGISTRY_ROOT=$(python3 -c "
raw = open('$fixtures/registration.inputs','rb').read(); print('0x' + raw[5*32:6*32].hex())")

export ZKICAO_EARLIEST_DATE=20260101

export ZKICAO_LATEST_DATE=20261231

context=$(python3 -c "
raw = open('$fixtures/registration.inputs','rb').read(); print('0x' + raw[32:64].hex()[24:])")

if [ "$(echo "$context" | tr 'A-Z' 'a-z')" != "$(echo "$sender" | tr 'A-Z' 'a-z')" ]; then
  echo "the proofs are bound to $context, not to $sender" >&2

  echo "reprove the bundle with ZKICAO_CONTEXT set to this sender" >&2

  exit 1
fi

forge script "$here/script/Deploy.s.sol" --rpc-url "$rpc" --private-key "$key" --broadcast >/dev/null

chain=$(cast chain-id --rpc-url "$rpc")

registry=$(python3 -c "
import json
d = json.load(open('$here/broadcast/Deploy.s.sol/$chain/run-latest.json'))
print(next(t['contractAddress'] for t in d['transactions'] if t.get('contractName') == 'ZkIcaoRegistry'))
")

echo "registry $registry"

read -r proof inputs nproof ninputs <<< "$(python3 -c "
from pathlib import Path

def blob(p):
    return '0x' + Path(p).read_bytes().hex()

def arr(p):
    raw = Path(p).read_bytes()
    return '[' + ','.join('0x' + raw[i:i+32].hex() for i in range(0, len(raw), 32)) + ']'

print(blob('$fixtures/registration.proof'), arr('$fixtures/registration.inputs'),
      blob('$fixtures/nullifier.proof'), arr('$fixtures/nullifier.inputs'))
")"

receipt=$(cast send "$registry" "register(bytes,bytes32[],bytes,bytes32[])" \
  "$proof" "$inputs" "$nproof" "$ninputs" --rpc-url "$rpc" --private-key "$key")

status=$(echo "$receipt" | awk '/^status/ {print $2}')

gas=$(echo "$receipt" | awk '/^gasUsed/ {print $2}')

echo "register status $status, gas $gas"

[ "$status" = "1" ] || { echo "the registration reverted" >&2; exit 1; }

commitment=$(python3 -c "
raw = open('$fixtures/registration.inputs','rb').read(); print('0x' + raw[2*32:3*32].hex())")

nullifier=$(python3 -c "
raw = open('$fixtures/nullifier.inputs','rb').read(); print('0x' + raw[4*32:5*32].hex())")

stored_commitment=$(cast call "$registry" "registeredCommitment(bytes32)(bool)" "$commitment" --rpc-url "$rpc")

stored_nullifier=$(cast call "$registry" "nullifierSeen(bytes32)(bool)" "$nullifier" --rpc-url "$rpc")

[ "$stored_commitment" = "true" ] && [ "$stored_nullifier" = "true" ] \
  || { echo "the registration succeeded but stored nothing" >&2; exit 1; }

echo "commitment and nullifier are on chain"

# The same document again must be refused, on chain and not only in a test.
if cast send "$registry" "register(bytes,bytes32[],bytes,bytes32[])" \
    "$proof" "$inputs" "$nproof" "$ninputs" --rpc-url "$rpc" --private-key "$key" >/dev/null 2>&1; then
  echo "a second registration of the same document was accepted" >&2

  exit 1
fi

echo "a second registration is refused"

echo
echo "the on chain path works on chain id $chain"
