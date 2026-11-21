#!/usr/bin/env bash
# Enforce the Requirement 5.3 layout of the kube-state repository (FR-010, Principle I).
# Usage: check-layout.sh [REPO_ROOT]   (default: current directory)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-.}"
cd "$ROOT"

# Release folders each cluster must contain (FR-010). More may be added following the pattern.
declare -A REQUIRED_RELEASES=([local]="shop-operator shophub shophub-discord")

errors=()
err() { errors+=("$1"); }

[[ -f README.md ]] || err "missing README.md at repository root"
[[ -d clusters ]] || err "missing clusters/ directory"
[[ -d clusters/local ]] || err "missing clusters/local/ directory"

# Only clusters/ may be a visible top-level directory (no parallel layouts).
for entry in */; do
  [[ -d "$entry" ]] || continue
  name="${entry%/}"
  [[ "$name" == clusters ]] || err "unexpected top-level directory: $name/ (only clusters/ is allowed)"
done

for cdir in clusters/*/; do
  [[ -d "$cdir" ]] || continue
  cdir="${cdir%/}"
  cluster="${cdir#clusters/}"
  [[ -f "$cdir/cluster.yaml" ]] || err "missing $cdir/cluster.yaml"

  for entry in "$cdir"/* "$cdir"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    base="${entry##*/}"
    if [[ -d "$entry" ]]; then
      # Release folder: exactly helm.yaml + values.yaml, nothing else (hidden entries included).
      [[ -f "$entry/helm.yaml" ]] || err "missing $entry/helm.yaml"
      [[ -f "$entry/values.yaml" ]] || err "missing $entry/values.yaml"
      for f in "$entry"/* "$entry"/.[!.]*; do
        [[ -e "$f" ]] || continue
        fb="${f##*/}"
        if [[ -d "$f" || ( "$fb" != helm.yaml && "$fb" != values.yaml ) ]]; then
          err "unexpected entry in release folder $entry/: $fb"
        fi
      done
    elif [[ "$base" != cluster.yaml ]]; then
      err "unexpected file in $cdir/: $base"
    fi
  done

  for r in ${REQUIRED_RELEASES[$cluster]-}; do
    [[ -d "$cdir/$r" ]] || err "missing release folder $cdir/$r/"
  done
done

if ((${#errors[@]})); then
  for e in "${errors[@]}"; do printf 'ERROR: %s\n' "$e" >&2; done
  printf 'layout check failed: %d problem(s)\n' "${#errors[@]}" >&2
  exit 1
fi
echo "layout OK"
