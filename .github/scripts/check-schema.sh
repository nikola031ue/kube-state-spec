#!/usr/bin/env bash
# Validate cluster.yaml, helm.yaml and values.yaml against
# specs/001-iac-foundation/contracts/kube-state-files.md (FR-011, FR-012, FR-015, FR-020).
# Usage: check-schema.sh [REPO_ROOT]   (default: current directory). Requires yq v4.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="${1:-.}"
cd "$ROOT"

errors=()
err() { errors+=("$1"); }

# q FILE DOC_INDEX EXPR -> yq result for one document ("null" when absent).
# eval-all + `[.] | .[i]`: exactly one value, no `---` separators, no per-doc repeats.
q() { yq eval-all "[.] | .[$2] | $3" "$1"; }

for cdir in clusters/*/; do
  [[ -d "$cdir" ]] || continue
  cdir="${cdir%/}"
  cluster="${cdir#clusters/}"
  cfile="$cdir/cluster.yaml"

  # Release folders present on disk.
  folders=()
  for d in "$cdir"/*/; do [[ -d "$d" ]] && { d="${d%/}"; folders+=("${d##*/}"); }; done

  # ---- cluster.yaml ----
  order=()
  if [[ ! -f "$cfile" ]]; then
    err "$cfile: missing"
  elif ! yq eval '.' "$cfile" >/dev/null 2>&1; then
    err "$cfile: invalid YAML"
  else
    [[ "$(yq eval 'tag' "$cfile")" == "!!map" ]] || err "$cfile: must be a mapping"
    [[ "$(yq eval 'has("apiVersion") or has("kind")' "$cfile")" == "false" ]] \
      || err "$cfile: must not be a Kubernetes object (remove apiVersion/kind)"
    [[ "$(yq eval '.name' "$cfile")" == "$cluster" ]] || err "$cfile: name must equal folder name '$cluster'"
    ctx="$(yq eval '.context // ""' "$cfile")"
    [[ -n "$ctx" ]] || err "$cfile: context is required"
    [[ -n "$(yq eval '.distribution // ""' "$cfile")" ]] || err "$cfile: distribution is required"
    if [[ "$(yq eval '.releaseOrder | tag' "$cfile")" != "!!seq" ]]; then
      err "$cfile: releaseOrder must be a list"
    else
      mapfile -t order < <(yq eval '.releaseOrder[]' "$cfile")
      declare -A seen=()
      for r in "${order[@]}"; do
        if [[ -n "${seen[$r]-}" ]]; then err "$cfile: releaseOrder lists '$r' more than once"; fi
        seen[$r]=1
        found=false
        for f in "${folders[@]}"; do [[ "$f" == "$r" ]] && found=true; done
        $found || err "$cfile: releaseOrder names unknown release '$r'"
      done
      for f in "${folders[@]}"; do
        [[ -n "${seen[$f]-}" ]] || err "$cfile: releaseOrder is missing release '$f'"
      done
      unset seen
    fi
  fi

  index_of() {
    local i
    for i in "${!order[@]}"; do [[ "${order[i]}" == "$1" ]] && { echo "$i"; return; }; done
    echo -1
  }

  # ---- per release ----
  for name in "${folders[@]}"; do
    rdir="$cdir/$name"
    h="$rdir/helm.yaml"
    v="$rdir/values.yaml"

    if [[ ! -f "$h" ]]; then
      err "$h: missing"
    elif ! yq eval '.' "$h" >/dev/null 2>&1; then
      err "$h: invalid YAML"
    else
      ndocs="$(yq eval-all '[.] | length' "$h")"
      if [[ "$ndocs" != 2 ]]; then
        err "$h: must contain exactly 2 documents (OCIRepository, HelmRelease), found $ndocs"
      else
        [[ "$(q "$h" 0 .kind)" == OCIRepository && "$(q "$h" 0 .apiVersion)" == source.toolkit.fluxcd.io/v1 ]] \
          || err "$h: document 1 must be OCIRepository (source.toolkit.fluxcd.io/v1)"
        [[ "$(q "$h" 1 .kind)" == HelmRelease && "$(q "$h" 1 .apiVersion)" == helm.toolkit.fluxcd.io/v2 ]] \
          || err "$h: document 2 must be HelmRelease (helm.toolkit.fluxcd.io/v2)"

        [[ "$(q "$h" 0 .metadata.name)" == "$name" ]] || err "$h: OCIRepository metadata.name must be '$name'"
        [[ "$(q "$h" 1 .metadata.name)" == "$name" ]] || err "$h: HelmRelease metadata.name must be '$name'"
        [[ "$(q "$h" 1 .spec.releaseName)" == "$name" ]] || err "$h: spec.releaseName must be '$name'"

        url="$(q "$h" 0 '.spec.url // ""')"
        [[ "$url" == "$OCI_BASE"/* && "$url" != "$OCI_BASE/" ]] \
          || err "$h: spec.url must start with $OCI_BASE/ (got '$url')"

        refkeys="$(q "$h" 0 '.spec.ref | keys | join(",")' 2>/dev/null || echo "")"
        tag="$(q "$h" 0 '.spec.ref.tag // ""')"
        if [[ "$refkeys" != tag ]]; then
          err "$h: spec.ref must contain only an exact tag (no semver range or digest)"
        elif ! semver_valid "$tag"; then
          err "$h: spec.ref.tag must be strict SemVer, got '$tag'"
        fi

        [[ -n "$(q "$h" 1 '.spec.targetNamespace // ""')" ]] || err "$h: spec.targetNamespace is required"
        [[ "$(q "$h" 1 .spec.chartRef.kind)" == OCIRepository && "$(q "$h" 1 .spec.chartRef.name)" == "$name" ]] \
          || err "$h: spec.chartRef must reference OCIRepository '$name'"

        [[ "$(q "$h" 1 '.spec.valuesFrom[0].kind')" == ConfigMap \
          && "$(q "$h" 1 '.spec.valuesFrom[0].name')" == "$name-values" \
          && "$(q "$h" 1 '.spec.valuesFrom[0].valuesKey')" == values.yaml ]] \
          || err "$h: spec.valuesFrom[0] must be ConfigMap '$name-values' with valuesKey values.yaml"

        self_idx="$(index_of "$name")"
        while IFS= read -r dep; do
          [[ -n "$dep" ]] || continue
          dep_idx="$(index_of "$dep")"
          if [[ ! -d "$cdir/$dep" ]]; then
            err "$h: dependsOn names unknown release '$dep'"
          elif (( dep_idx < 0 || self_idx < 0 || dep_idx >= self_idx )); then
            err "$cfile: releaseOrder must list '$dep' before '$name' (dependsOn)"
          fi
        done < <(q "$h" 1 '.spec.dependsOn[]?.name')
      fi
    fi

    if [[ ! -f "$v" ]]; then
      err "$v: missing"
    elif ! yq eval '.' "$v" >/dev/null 2>&1; then
      err "$v: invalid YAML"
    else
      vtag="$(yq eval 'tag' "$v")"
      [[ "$vtag" == "!!map" || "$vtag" == "!!null" ]] || err "$v: values.yaml must be a mapping (got $vtag)"
    fi
  done
done

if ((${#errors[@]})); then
  for e in "${errors[@]}"; do printf 'ERROR: %s\n' "$e" >&2; done
  printf 'schema check failed: %d problem(s)\n' "${#errors[@]}" >&2
  exit 1
fi
echo "schema OK"
