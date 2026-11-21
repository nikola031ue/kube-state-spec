#!/usr/bin/env bash
# Shared helpers for kube-state CI scripts and bring-up.sh. Source, do not execute.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# Strict SemVer 2.0 (https://semver.org) — no leading "v".
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(\+([0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*))?$'

semver_valid() { [[ "$1" =~ $SEMVER_RE ]]; }

# yq_doc FILE KIND EXPR -> evaluate EXPR on the document of FILE whose .kind == KIND.
yq_doc() {
  local file="$1" kind="$2" expr="$3"
  # eval-all + `[…] | .[0]`: exactly one value, no `---` separators, no per-doc repeats.
  yq eval-all "[select(.kind == \"${kind}\")] | .[0] | ${expr}" "$file"
}

# Prefix every chart URL in helm.yaml must start with (research.md R8).
OCI_BASE="${OCI_BASE:-oci://ghcr.io/nikola031ue/charts}"
