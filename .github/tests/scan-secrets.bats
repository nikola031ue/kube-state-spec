#!/usr/bin/env bats
# Tests for .github/scripts/scan-secrets.sh (FR-013, Principle VI).

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/scan-secrets.sh"
  F="$BATS_TEST_TMPDIR/values.yaml"
}

@test "flags a literal password" {
  printf 'db:\n  password: abc\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -ne 0 ]
  [[ "$output" == *"db.password"* ]]
}

@test "flags a literal token (case-insensitive key match)" {
  printf 'discordToken: x\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -ne 0 ]
  [[ "$output" == *"discordToken"* ]]
}

@test "flags secret-like keys inside lists" {
  printf 'wallets:\n  - privateKey: "0xabc"\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -ne 0 ]
  [[ "$output" == *"privateKey"* ]]
}

@test "flags apiKey" {
  printf 'rpc:\n  apiKey: 12345\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -ne 0 ]
}

@test "allows existingSecret references" {
  printf 'auth:\n  existingSecret: foo\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -eq 0 ]
}

@test "allows *SecretName references" {
  printf 'discord:\n  tokenSecretName: bar\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -eq 0 ]
}

@test "allows empty values" {
  printf 'password: ""\ntoken:\napiKey: null\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -eq 0 ]
}

@test "ignores booleans such as tokenEnabled" {
  printf 'tokenEnabled: true\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -eq 0 ]
}

@test "passes on an empty mapping and on comments-only files" {
  echo '{}' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -eq 0 ]
  printf '# nothing\n' > "$F"
  run bash "$SCRIPT" "$F"
  [ "$status" -eq 0 ]
}

@test "scans several files and names the offending one" {
  printf 'a: 1\n' > "$BATS_TEST_TMPDIR/ok.yaml"
  printf 'secret: s3cr3t\n' > "$BATS_TEST_TMPDIR/bad.yaml"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/ok.yaml" "$BATS_TEST_TMPDIR/bad.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad.yaml"* ]]
  [[ "$output" != *"ok.yaml"* ]]
}
