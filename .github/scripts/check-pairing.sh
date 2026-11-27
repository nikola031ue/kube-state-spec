#!/usr/bin/env bash
# Version pairs that must not run together (spec 005 T024, hard rollout rule).
# shop-operator chart >= 0.5.0 ships a delete guard that refuses a Shop DELETE without
# shophub.io/delete-requested; ShopHub writes that annotation from 0.3.0 on. With an older
# ShopHub every panel delete would fail, so the pair is refused here.
# Usage: check-pairing.sh [REPO_ROOT]   (default: current directory). Requires yq v4.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-.}"
cd "$ROOT"

GUARD_CHART=0.5.0   # first shop-operator chart with the delete guard
MIN_SHOPHUB=0.3.0   # first ShopHub that annotates before deleting

# ver_lt A B -> true when SemVer A < B. A pre-release sorts before its release (0.3.0-rc.1 < 0.3.0).
ver_lt() {
  local a="${1%%+*}" b="${2%%+*}" ca cb
  ca="${a%%-*}" cb="${b%%-*}"
  if [[ "$ca" == "$cb" ]]; then
    [[ "$a" == *-* && "$b" != *-* ]]
    return
  fi
  [[ "$(printf '%s\n%s\n' "$ca" "$cb" | sort -V | head -n1)" == "$ca" ]]
}

failed=0
for c in clusters/*/; do
  c="${c%/}"
  op="$c/shop-operator/helm.yaml"
  hub="$c/shophub/values.yaml"
  [[ -f "$op" ]] || continue
  chart="$(yq_doc "$op" OCIRepository '.spec.ref.tag // ""')"
  semver_valid "$chart" || { echo "::error file=$op::shop-operator chart version '$chart' is not SemVer"; failed=1; continue; }
  ver_lt "$chart" "$GUARD_CHART" && { echo "ok: $c shop-operator chart $chart (no delete guard)"; continue; }

  tag=""
  [[ -f "$hub" ]] && tag="$(yq eval '.image.tag // ""' "$hub")"
  if [[ -z "$tag" ]]; then
    echo "::error file=$hub::shop-operator chart $chart needs ShopHub >= $MIN_SHOPHUB; set image.tag in $hub explicitly"
    failed=1
  elif ! semver_valid "$tag" || ver_lt "$tag" "$MIN_SHOPHUB"; then
    echo "::error file=$op::shop-operator chart $chart (delete guard) needs ShopHub image >= $MIN_SHOPHUB, but $hub has '$tag'. Roll out ShopHub $MIN_SHOPHUB first."
    failed=1
  else
    echo "ok: $c shop-operator chart $chart with ShopHub $tag"
  fi
done
exit $failed
