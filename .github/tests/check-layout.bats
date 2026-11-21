#!/usr/bin/env bats
# Tests for .github/scripts/check-layout.sh (FR-010, Principle I).

load helpers

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-layout.sh"
  ROOT="$BATS_TEST_TMPDIR/repo"
  make_fixture "$ROOT"
}

@test "passes on the correct tree" {
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
}

@test "fails when README.md is missing" {
  rm "$ROOT/README.md"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"README.md"* ]]
}

@test "fails when clusters/local is missing" {
  rm -r "$ROOT/clusters/local"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"clusters/local"* ]]
}

@test "fails when cluster.yaml is missing" {
  rm "$ROOT/clusters/local/cluster.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cluster.yaml"* ]]
}

@test "fails when a release folder lacks helm.yaml" {
  rm "$ROOT/clusters/local/shophub/helm.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shophub/helm.yaml"* ]]
}

@test "fails when a release folder lacks values.yaml" {
  rm "$ROOT/clusters/local/shop-operator/values.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shop-operator/values.yaml"* ]]
}

@test "fails when a release folder has an extra file" {
  touch "$ROOT/clusters/local/shophub/kustomization.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kustomization.yaml"* ]]
}

@test "fails when a release folder has an extra hidden file" {
  touch "$ROOT/clusters/local/shophub/.keep"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *".keep"* ]]
}

@test "fails when a release folder has a nested directory" {
  mkdir -p "$ROOT/clusters/local/shophub/extra"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extra"* ]]
}

@test "fails on an unexpected file in the cluster folder" {
  touch "$ROOT/clusters/local/notes.yaml"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"notes.yaml"* ]]
}

@test "fails on a parallel top-level folder" {
  mkdir -p "$ROOT/environments"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"environments"* ]]
}

@test "allows hidden top-level folders such as .github" {
  mkdir -p "$ROOT/.github/workflows"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -eq 0 ]
}

@test "fails when the three required release folders are not all present" {
  rm -r "$ROOT/clusters/local/shophub-discord"
  run bash "$SCRIPT" "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shophub-discord"* ]]
}
