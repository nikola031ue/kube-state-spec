#!/usr/bin/env bats
# Tests for .github/scripts/check-schema.sh (FR-011, FR-012, FR-015, FR-020;
# rules from specs/001-iac-foundation/contracts/kube-state-files.md).

load helpers

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-schema.sh"
  ROOT="$BATS_TEST_TMPDIR/repo"
  C="$ROOT/clusters/local"
  make_fixture "$ROOT"
}

@test "passes on valid files" {
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
}

# ---- cluster.yaml ----

@test "fails when cluster.yaml is a Kubernetes object" {
  sed -i '1i apiVersion: v1\nkind: Cluster' "$C/cluster.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"apiVersion"* ]]
}

@test "fails when cluster.yaml name differs from folder" {
  sed -i 's/^name: local/name: prod/' "$C/cluster.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"name"* ]]
}

@test "fails when cluster.yaml has no context" {
  sed -i '/^context:/d' "$C/cluster.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"context"* ]]
}

@test "fails when releaseOrder misses a release folder" {
  sed -i '/  - shophub-discord/d' "$C/cluster.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shophub-discord"* ]]
}

@test "fails when releaseOrder names an unknown release" {
  echo '  - ghost' >> "$C/cluster.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ghost"* ]]
}

@test "fails when releaseOrder lists a release twice" {
  echo '  - shophub' >> "$C/cluster.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shophub"* ]]
}

@test "fails when a dependency is listed after its dependent" {
  cat > "$C/cluster.yaml" <<'EOF'
name: local
context: docker-desktop
distribution: docker-desktop
releaseOrder:
  - shophub
  - shop-operator
  - shophub-discord
EOF
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shop-operator"* ]]
}

# ---- helm.yaml ----

@test "fails when helm.yaml has only one document" {
  yq -i 'select(.kind == "OCIRepository")' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shophub/helm.yaml"* ]]
}

@test "fails when helm.yaml has a third document (no other objects allowed)" {
  printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n' >> "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shophub/helm.yaml"* ]]
}

@test "fails when helm.yaml contains a user Shop resource (FR-015)" {
  yq -i 'select(.kind == "HelmRelease") |= (.kind = "Shop")' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HelmRelease"* ]]
}

@test "fails when OCIRepository name differs from folder" {
  yq -i 'select(.kind == "OCIRepository").metadata.name = "other"' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"metadata.name"* ]]
}

@test "fails when releaseName differs from folder" {
  yq -i 'select(.kind == "HelmRelease").spec.releaseName = "other"' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"releaseName"* ]]
}

@test "fails when chart URL is outside the project registry" {
  write_release "$C" shophub shophub shop-operator 0.1.0 oci://docker.io/someone/shophub
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"url"* ]]
}

@test "fails when tag is not strict SemVer" {
  write_release "$C" shophub shophub shop-operator v0.1
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag"* ]]
}

@test "fails when tag is latest" {
  write_release "$C" shophub shophub shop-operator latest
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag"* ]]
}

@test "fails when OCIRepository uses a semver range instead of a tag" {
  yq -i 'select(.kind == "OCIRepository").spec.ref = {"semver": ">=0.1.0"}' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tag"* ]]
}

@test "fails when targetNamespace is missing" {
  yq -i 'select(.kind == "HelmRelease") |= del(.spec.targetNamespace)' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"targetNamespace"* ]]
}

@test "fails when chartRef does not point at the OCIRepository" {
  yq -i 'select(.kind == "HelmRelease").spec.chartRef.name = "other"' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chartRef"* ]]
}

@test "fails when dependsOn names an unknown release" {
  yq -i 'select(.kind == "HelmRelease").spec.dependsOn[0].name = "ghost"' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ghost"* ]]
}

@test "fails when valuesFrom name is wrong" {
  yq -i 'select(.kind == "HelmRelease").spec.valuesFrom[0].name = "values"' "$C/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"valuesFrom"* ]]
}

# ---- values.yaml ----

@test "accepts a comments-only values.yaml" {
  printf '# no overrides\n' > "$C/shophub/values.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
}

@test "fails when values.yaml is not a mapping" {
  printf -- '- a\n- b\n' > "$C/shophub/values.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"values.yaml"* ]]
}

@test "fails when values.yaml is invalid YAML" {
  printf 'a: [unclosed\n' > "$C/shophub/values.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"values.yaml"* ]]
}
