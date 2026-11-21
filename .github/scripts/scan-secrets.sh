#!/usr/bin/env bash
# Reject literal secret values in values.yaml files (FR-013, Constitution Principle VI).
# A value is flagged when its key matches password|token|secret|privatekey|apikey
# (case-insensitive), it is a non-empty string or a number, and the key is not a reference
# by name (…SecretName, existingSecret, …SecretRef, secretKeyRef).
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
