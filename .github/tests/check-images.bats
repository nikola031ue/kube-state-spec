#!/usr/bin/env bats
# Tests for .github/scripts/check-images.sh (Constitution Principle II; data-model Chart.appVersion).

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-images.sh"
  M="$BATS_TEST_TMPDIR/manifest.yaml"
}

deployment() {
  cat > "$M" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: d }
spec:
  template:
    spec:
      initContainers:
        - name: init
          image: busybox:1.36.1
      containers:
        - name: app
          image: $1
EOF
}

@test "pinned tag passes" {
  deployment nginx:1.27.3
  run bash "$SCRIPT" < "$M"
  [ "$status" -eq 0 ]
}

@test "digest-pinned image passes" {
  deployment "nginx@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  run bash "$SCRIPT" < "$M"
  [ "$status" -eq 0 ]
}

@test "registry with port and pinned tag passes" {
  deployment "registry.local:5000/team/app:2.0.1"
  run bash "$SCRIPT" < "$M"
  [ "$status" -eq 0 ]
}

@test "image without tag fails" {
  deployment nginx
  run bash "$SCRIPT" < "$M"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nginx"* ]]
}

@test "registry with port but no tag fails" {
  deployment "registry.local:5000/team/app"
  run bash "$SCRIPT" < "$M"
  [ "$status" -ne 0 ]
}

@test "latest tag fails" {
  deployment nginx:latest
  run bash "$SCRIPT" < "$M"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nginx:latest"* ]]
}

@test "empty manifest stream passes" {
  run bash "$SCRIPT" < /dev/null
  [ "$status" -eq 0 ]
}

@test "--charts: appVersion latest fails" {
  mkdir -p "$BATS_TEST_TMPDIR/c1"
  printf 'apiVersion: v2\nname: c1\nversion: 0.1.0\nappVersion: latest\n' > "$BATS_TEST_TMPDIR/c1/Chart.yaml"
  run bash "$SCRIPT" --charts "$BATS_TEST_TMPDIR/c1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"appVersion"* ]]
}

@test "--charts: pinned appVersion passes" {
  mkdir -p "$BATS_TEST_TMPDIR/c2"
  printf 'apiVersion: v2\nname: c2\nversion: 0.1.0\nappVersion: "1.27.3"\n' > "$BATS_TEST_TMPDIR/c2/Chart.yaml"
  run bash "$SCRIPT" --charts "$BATS_TEST_TMPDIR/c2"
  [ "$status" -eq 0 ]
}
