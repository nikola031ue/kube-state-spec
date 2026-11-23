#!/usr/bin/env bash
# Bring up the ShopHub platform on a cluster using only this repository.
# Contract: shophub-specs/specs/001-iac-foundation/contracts/bring-up-cli.md
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./bring-up.sh [CLUSTER]      CLUSTER defaults to "local"
       ./bring-up.sh --help

Installs or upgrades every release listed in clusters/<CLUSTER>/cluster.yaml (releaseOrder),
using the chart OCI name + exact version from each helm.yaml and overrides from values.yaml.
Skips releases that are already deployed with the same chart version and values.

Environment:
  HELM_TIMEOUT       timeout per release for helm --wait          (default 5m)
  CRD_WAIT_TIMEOUT   timeout per CRD for condition=Established    (default 120s)

Exit codes: 0 ok | 1 release failed | 2 missing tool | 3 invalid cluster.yaml/helm.yaml/values.yaml
            4 wrong kube context | 5 CRD not Established | 6 chart/registry not reachable
EOF
}

case "${1-}" in -h|--help) usage; exit 0 ;; esac

CLUSTER="${1:-local}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"
CRD_WAIT_TIMEOUT="${CRD_WAIT_TIMEOUT:-120s}"

fail() { printf 'ERROR: %s\n' "$2" >&2; exit "$1"; }

cd "$(dirname "${BASH_SOURCE[0]}")"

# ---- 0. prerequisites (exit 2) ----
for tool in helm kubectl yq jq; do
  command -v "$tool" >/dev/null 2>&1 || fail 2 "required tool '$tool' not found in PATH (see README.md Prerequisites)"
done
helm_v="$(helm version --short 2>/dev/null || true)"; helm_v="${helm_v#v}"; helm_v="${helm_v%%+*}"
IFS=. read -r hmaj hmin _ <<<"$helm_v"
if ! [[ "$hmaj" =~ ^[0-9]+$ && "$hmin" =~ ^[0-9]+$ ]] || (( hmaj < 3 || (hmaj == 3 && hmin < 8) )); then
  fail 2 "helm >= 3.8 required (OCI support), found '${helm_v:-unknown}'"
fi
yq --version 2>/dev/null | grep -q 'version v4' || fail 2 "yq v4 (mikefarah/yq) required"

# ---- 1. cluster.yaml (exit 3) ----
CDIR="clusters/$CLUSTER"
CFILE="$CDIR/cluster.yaml"
[[ -f "$CFILE" ]] || fail 3 "$CFILE not found"
yq eval '.' "$CFILE" >/dev/null 2>&1 || fail 3 "$CFILE is not valid YAML"
CONTEXT="$(yq eval '.context // ""' "$CFILE")"
[[ -n "$CONTEXT" ]] || fail 3 "$CFILE: 'context' is required"
mapfile -t RELEASES < <(yq eval '.releaseOrder[]' "$CFILE" 2>/dev/null)
(( ${#RELEASES[@]} )) || fail 3 "$CFILE: 'releaseOrder' must list at least one release"

# ---- 2. context guard (exit 4) ----
current="$(kubectl config current-context 2>/dev/null || true)"
[[ "$current" == "$CONTEXT" ]] \
  || fail 4 "current kube context is '${current:-<none>}', expected '$CONTEXT' (from $CFILE). Run: kubectl config use-context $CONTEXT"
# helm and kubectl spell the context flag differently.
KC=(--kube-context "$CONTEXT")   # helm
KCTL=(--context "$CONTEXT")      # kubectl

echo "[cluster] $CLUSTER (context $CONTEXT)"

is_registry_error() {
  grep -qiE 'not found|manifest unknown|denied|unauthorized|forbidden|40[13]|no such host|dial tcp|i/o timeout|connection refused|tls:' <<<"$1"
}

# field FILE KIND PATH -> single scalar from the document of FILE with that kind ("" if absent).
# eval-all + `[…] | .[0]` returns exactly one value (no `---` separators, no per-doc repeats).
field() {
  yq eval-all "[select(.kind == \"$2\")] | .[0] | $3 // \"\"" "$1" 2>/dev/null || true
}

crd_names() { # stdin: manifests -> CRD names
  yq eval-all 'select(.kind == "CustomResourceDefinition") | .metadata.name' - 2>/dev/null | grep -v -e '^---$' -e '^null$' -e '^$' || true
}

n=${#RELEASES[@]}

# ---- 3.1 validate every release folder before touching the cluster (exit 3) ----
URLS=() VERSIONS=() NAMES=() NSS=()
for rel_dir in "${RELEASES[@]}"; do
  H="$CDIR/$rel_dir/helm.yaml"
  V="$CDIR/$rel_dir/values.yaml"
  [[ -f "$H" ]] || fail 3 "$rel_dir: $H not found"
  [[ -f "$V" ]] || fail 3 "$rel_dir: $V not found"
  yq eval-all '.' "$H" >/dev/null 2>&1 || fail 3 "$rel_dir: $H is not valid YAML"
  yq eval -o json '.' "$V" >/dev/null 2>&1 || fail 3 "$rel_dir: $V is not valid YAML"
  [[ "$(yq eval '. | type' "$V")" =~ ^!!(map|null)$ ]] || fail 3 "$rel_dir: $V must be a YAML mapping"

  url="$(field "$H" OCIRepository .spec.url)"
  version="$(field "$H" OCIRepository .spec.ref.tag)"
  release="$(field "$H" HelmRelease .spec.releaseName)"
  ns="$(field "$H" HelmRelease .spec.targetNamespace)"
  [[ -n "$url" && -n "$version" && -n "$release" && -n "$ns" ]] \
    || fail 3 "$rel_dir: $H must define OCIRepository spec.url/spec.ref.tag and HelmRelease spec.releaseName/spec.targetNamespace"
  URLS+=("$url") VERSIONS+=("$version") NAMES+=("$release") NSS+=("$ns")
done

installed=0 upgraded=0 unchanged=0
summary=()

for i in "${!RELEASES[@]}"; do
  rel_dir="${RELEASES[i]}"
  step="[$((i + 1))/$n]"
  V="$CDIR/$rel_dir/values.yaml"
  url="${URLS[i]}" version="${VERSIONS[i]}" release="${NAMES[i]}" ns="${NSS[i]}"
  chart="${url##*/}"

  # ---- 3.2 desired vs deployed ----
  list="$(helm list -n "$ns" -a -o json --filter "^${release}\$" "${KC[@]}")"
  dep_chart="$(jq -r '.[0].chart // ""' <<<"$list")"
  dep_status="$(jq -r '.[0].status // ""' <<<"$list")"
  dep_version="${dep_chart#"${chart}-"}"

  result=""
  if [[ "$dep_status" == deployed && "$dep_version" == "$version" ]]; then
    have="$(helm get values "$release" -n "$ns" -o json "${KC[@]}" | jq -S '. // {}')"
    want="$(yq eval -o json '.' "$V" | jq -S '. // {}')"
    [[ "$have" == "$want" ]] && result=unchanged
  fi

  # ---- 3.3 install / upgrade ----
  # --reset-values: values.yaml is the only source. Without it Helm 3 copies the previous
  # release's values when values.yaml is empty, so removing an override never takes effect.
  if [[ -z "$result" ]]; then
    if [[ -z "$dep_status" ]]; then result=installed; else result=upgraded; fi
    if ! out="$(helm upgrade --install "$release" "$url" --version "$version" -n "$ns" --create-namespace \
                  -f "$V" --reset-values --wait --timeout "$HELM_TIMEOUT" "${KC[@]}" 2>&1)"; then
      printf '%s\n' "$out" >&2
      if is_registry_error "$out"; then
        fail 6 "$release: chart $url version $version could not be pulled (missing version or registry unreachable)"
      fi
      fail 1 "$release: helm upgrade --install failed; later releases were not attempted"
    fi
  fi
  case "$result" in
    installed) installed=$((installed + 1)) ;;
    upgraded) upgraded=$((upgraded + 1)) ;;
    unchanged) unchanged=$((unchanged + 1)) ;;
  esac
  printf '%s %-16s %-7s %-22s %s\n' "$step" "$release" "$version" "$ns" "$result"
  summary+=("$(printf '%-16s %-7s %-22s %s' "$release" "$version" "$ns" "$result")")

  # ---- 3.4 wait for CRDs provided by this release (FR-023) ----
  if ! shown="$(helm show crds "$url" --version "$version" "${KC[@]}" 2>&1)"; then
    printf '%s\n' "$shown" >&2
    fail 6 "$release: could not read CRDs of $url version $version"
  fi
  manifest="$(helm get manifest "$release" -n "$ns" "${KC[@]}" 2>/dev/null || true)"
  mapfile -t crds < <({ crd_names <<<"$shown"; crd_names <<<"$manifest"; } | sort -u)
  if (( ${#crds[@]} == 0 )); then
    printf '%s %-16s crds: none\n' "$step" "$release"
  else
    for c in "${crds[@]}"; do
      if ! out="$(kubectl wait --for=condition=Established "crd/$c" --timeout="$CRD_WAIT_TIMEOUT" "${KCTL[@]}" 2>&1)"; then
        printf '%s\n' "$out" >&2
        fail 5 "$release: CRD '$c' not Established within $CRD_WAIT_TIMEOUT; later releases were not attempted"
      fi
    done
    printf '%s %-16s crds: %s Established\n' "$step" "$release" "$(IFS=,; echo "${crds[*]}")"
  fi
done

echo
printf '%-16s %-7s %-22s %s\n' RELEASE VERSION NAMESPACE RESULT
printf '%s\n' "${summary[@]}"
echo "done: $installed installed, $upgraded upgraded, $unchanged unchanged"
