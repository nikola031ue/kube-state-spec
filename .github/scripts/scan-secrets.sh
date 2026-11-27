#!/usr/bin/env bash
# Reject literal secret values in values.yaml files (FR-013, Constitution Principle VI).
# A value is flagged when its key matches password|token|secret|privatekey|apikey
# (case-insensitive), it is a non-empty string or a number, and the key is not a reference
# by name (…SecretName, existingSecret, …SecretRef, secretKeyRef). A key ending in "address"
# holding exactly an Ethereum address (0x + 40 hex, public by definition, spec 005
# payments.tokenAddress) is not a secret; a 64-hex private key under such a key still is.
# Usage: scan-secrets.sh FILE...   Requires yq v4 and jq.
set -euo pipefail

(($#)) || { echo "usage: scan-secrets.sh FILE..." >&2; exit 2; }

JQ_FILTER='
  [ paths(scalars) as $p
    | { key: ($p | map(select(type == "string")) | last),
        path: ($p | map(tostring) | join(".")),
        value: getpath($p) } ]
  | .[]
  | select(.key != null)
  | select(.key | test("password|token|secret|privatekey|apikey"; "i"))
  | select(.key | test("(secretname|existingsecret|secretref|secretkeyref)$"; "i") | not)
  | select(((.value | type) == "string" and .value != "") or (.value | type) == "number")
  | select((.key | test("address$"; "i")) and ((.value | type) == "string")
           and (.value | test("^0x[0-9a-fA-F]{40}$")) | not)
  | .path
'

found=0
for f in "$@"; do
  if ! json="$(yq eval -o json '.' "$f" 2>/dev/null)"; then
    printf 'ERROR: %s: invalid YAML\n' "$f" >&2
    found=1
    continue
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    printf 'ERROR: %s: literal secret value at "%s" — reference a Secret by name instead\n' "$f" "$path" >&2
    found=1
  done < <(jq -r "$JQ_FILTER" <<<"$json")
done

if ((found)); then exit 1; fi
echo "secrets scan OK: $# file(s)"
