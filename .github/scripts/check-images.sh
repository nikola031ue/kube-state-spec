#!/usr/bin/env bash
# Reject unpinned container images (Constitution Principle II: never `latest`).
#   helm template … | check-images.sh          check every `image:` in the manifest stream
#   check-images.sh --charts DIR...            check Chart.yaml appVersion of each chart dir
# Self-contained (requires yq v4 for stream mode); identical copy lives in kube-state.
set -euo pipefail

errors=()

if [[ "${1-}" == --charts ]]; then
  shift
  for d in "$@"; do
    f="$d/Chart.yaml"
    [[ -f "$f" ]] || { errors+=("$f: missing"); continue; }
    av="$(sed -n -E "s/^appVersion:[[:space:]]*[\"']?([^\"'#[:space:]]*)[\"']?.*$/\1/p" "$f" | head -n1)"
    [[ "$av" != latest ]] || errors+=("$f: appVersion must not be 'latest'")
  done
else
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    if [[ "$img" == *@sha256:* ]]; then continue; fi        # digest-pinned
    last="${img##*/}"
    if [[ "$last" != *:* ]]; then
      errors+=("image '$img' has no tag — pin an explicit version")
    elif [[ "${last##*:}" == latest ]]; then
      errors+=("image '$img' uses the 'latest' tag — pin an explicit version")
    fi
  done < <(yq eval-all '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' -)
fi

if ((${#errors[@]})); then
  for e in "${errors[@]}"; do printf 'ERROR: %s\n' "$e" >&2; done
  exit 1
fi
echo "image check OK"
