#!/usr/bin/env bats
# Tests for .github/scripts/check-pairing.sh (spec 005 T024: operator chart >= 0.5.0 only with ShopHub >= 0.3.0).

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-pairing.sh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/clusters/local/shop-operator" "$R/clusters/local/shophub"
}

pair() { # pair OPERATOR_CHART SHOPHUB_TAG ("" = no image.tag)
  cat > "$R/clusters/local/shop-operator/helm.yaml" <<YAML
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata: { name: shop-operator, namespace: flux-system }
spec:
  url: oci://ghcr.io/nikola031ue/charts/shop-operator
  ref:
    tag: "$1"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: shop-operator, namespace: flux-system }
spec:
  releaseName: shop-operator
YAML
  if [[ -n "$2" ]]; then
    printf 'image:\n  tag: "%s"\nhost: shophub.localhost\n' "$2" > "$R/clusters/local/shophub/values.yaml"
  else
    printf 'host: shophub.localhost\n' > "$R/clusters/local/shophub/values.yaml"
  fi
}

@test "chart 0.5.0 with ShopHub 0.3.0 passes" {
  pair 0.5.0 0.3.0
  run bash "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
}

@test "chart 0.5.0 with a newer ShopHub passes (0.10.0 sorts as a number)" {
  pair 0.5.0 0.10.0
  run bash "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
}

@test "chart 0.4.0 with ShopHub 0.2.0 passes (no guard yet)" {
  pair 0.4.0 0.2.0
  run bash "$SCRIPT" "$R"
  [ "$status" -eq 0 ]
}

@test "chart 0.5.0 with ShopHub 0.2.0 fails and names both" {
  pair 0.5.0 0.2.0
  run bash "$SCRIPT" "$R"
  [ "$status" -ne 0 ]
  [[ "$output" == *"chart 0.5.0"* ]]
  [[ "$output" == *"'0.2.0'"* ]]
  [[ "$output" == *"Roll out ShopHub 0.3.0 first"* ]]
}

@test "a later chart (0.6.0) with ShopHub 0.2.9 fails" {
  pair 0.6.0 0.2.9
  run bash "$SCRIPT" "$R"
  [ "$status" -ne 0 ]
}

@test "chart 0.5.0 with a ShopHub 0.3.0 pre-release fails" {
  pair 0.5.0 0.3.0-rc.1
  run bash "$SCRIPT" "$R"
  [ "$status" -ne 0 ]
}

@test "chart 0.5.0 without an explicit ShopHub image.tag fails" {
  pair 0.5.0 ""
  run bash "$SCRIPT" "$R"
  [ "$status" -ne 0 ]
  [[ "$output" == *"set image.tag"* ]]
}
