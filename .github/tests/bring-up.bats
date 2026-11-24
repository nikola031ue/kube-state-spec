#!/usr/bin/env bats
# Tests for bring-up.sh against contracts/bring-up-cli.md (FR-019–FR-023), with stub helm/kubectl.

load helpers

setup() {
  ROOT="$BATS_TEST_TMPDIR/repo"
  make_fixture "$ROOT"
  cp "$BATS_TEST_DIRNAME/../../bring-up.sh" "$ROOT/bring-up.sh"
  chmod +x "$ROOT/bring-up.sh"
  STUBS="$BATS_TEST_DIRNAME/stubs"
  chmod +x "$STUBS"/* 2>/dev/null || true
  export PATH="$STUBS:$PATH"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : > "$STUB_LOG"
  cd "$ROOT"
}

deployed() { # deployed REL CHART-VERSION [STATUS]
  echo "[{\"name\":\"$1\",\"namespace\":\"x\",\"chart\":\"$2\",\"status\":\"${3:-deployed}\"}]"
}

all_deployed() {
  export HELM_LIST_SHOP_OPERATOR="$(deployed shop-operator shop-operator-0.1.0)"
  export HELM_LIST_SHOPHUB="$(deployed shophub shophub-0.1.0)"
  export HELM_LIST_SHOPHUB_DISCORD="$(deployed shophub-discord shophub-discord-0.1.0)"
}

crd() { # crd NAME -> CRD manifest
  printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: %s\n---\n' "$1"
}

# ---- usage / prerequisites / inputs ----

@test "--help prints usage and exits 0" {
  run ./bring-up.sh --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "missing tool -> exit 2" {
  bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  cp "$STUBS/helm" "$STUBS/kubectl" "$bin/"
  ln -s "$(command -v jq)" "$bin/jq"
  PATH="$bin:/usr/bin:/bin" command -v yq >/dev/null && skip "yq is in /usr/bin on this host"
  PATH="$bin:/usr/bin:/bin" run ./bring-up.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"yq"* ]]
}

@test "helm older than 3.8 -> exit 2" {
  HELM_VERSION=v3.7.2 run ./bring-up.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"helm"* ]]
}

@test "unknown cluster -> exit 3" {
  run ./bring-up.sh prod
  [ "$status" -eq 3 ]
  [[ "$output" == *"clusters/prod/cluster.yaml"* ]]
}

@test "invalid cluster.yaml -> exit 3" {
  printf 'context: [broken\n' > clusters/local/cluster.yaml
  run ./bring-up.sh
  [ "$status" -eq 3 ]
}

@test "release missing helm.yaml -> exit 3" {
  rm clusters/local/shophub/helm.yaml
  run ./bring-up.sh
  [ "$status" -eq 3 ]
  [[ "$output" == *"shophub"* ]]
}

@test "invalid values.yaml in a later release -> exit 3 before any release is installed" {
  printf '{}\nreplicaCount: 2\n' > clusters/local/shophub-discord/values.yaml
  run ./bring-up.sh
  [ "$status" -eq 3 ]
  [[ "$output" == *"shophub-discord"*"values.yaml"*"not valid YAML"* ]]
  [ -z "$(grep '^helm upgrade' "$STUB_LOG")" ]
}

@test "values.yaml that is not a mapping -> exit 3" {
  printf -- '- a\n- b\n' > clusters/local/shophub/values.yaml
  run ./bring-up.sh
  [ "$status" -eq 3 ]
  [[ "$output" == *"must be a YAML mapping"* ]]
}

@test "invalid helm.yaml in a later release -> exit 3 before any release is installed" {
  printf 'kind: [broken\n' > clusters/local/shophub-discord/helm.yaml
  run ./bring-up.sh
  [ "$status" -eq 3 ]
  [[ "$output" == *"shophub-discord"* ]]
  [ -z "$(grep '^helm upgrade' "$STUB_LOG")" ]
}

# ---- context guard (FR-021) ----

@test "context mismatch -> exit 4 and no helm call besides version" {
  KUBE_CONTEXT=minikube run ./bring-up.sh
  [ "$status" -eq 4 ]
  [[ "$output" == *"minikube"* && "$output" == *"docker-desktop"* ]]
  [ -z "$(grep '^helm' "$STUB_LOG" | grep -v '^helm version')" ]
}

@test "every cluster-touching call carries the context (helm --kube-context, kubectl --context)" {
  export HELM_CRDS_SHOP_OPERATOR="$(crd shops.shophub.io)"   # exercise kubectl wait too
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  missing="$(grep -E '^helm' "$STUB_LOG" | grep -v '^helm version' | grep -v -- '--kube-context docker-desktop' || true)"
  [ -z "$missing" ]
  grep -q '^kubectl wait' "$STUB_LOG"
  missing="$(grep -E '^kubectl' "$STUB_LOG" | grep -v 'config current-context' | grep -v -- '--context docker-desktop' || true)"
  [ -z "$missing" ]
}

@test "regression: kubectl never gets helm's --kube-context flag (CRD wait failed on real CRDs)" {
  export HELM_CRDS_SHOP_OPERATOR="$(crd shops.shophub.io)"
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"crds: shops.shophub.io Established"* ]]
  ! grep -E '^kubectl .*--kube-context' "$STUB_LOG"
}

@test "a failing CRD wait shows kubectl's own error" {
  export HELM_CRDS_SHOP_OPERATOR="$(crd shops.shophub.io)"
  export KUBECTL_WAIT_FAIL=shops.shophub.io
  run ./bring-up.sh
  [ "$status" -eq 5 ]
  [[ "$output" == *"timed out waiting for the condition"* ]]
}

# ---- install order and results (FR-020) ----

@test "fresh cluster: installs releases in releaseOrder" {
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  order="$(grep '^helm upgrade --install' "$STUB_LOG" | awk '{print $4}' | tr '\n' ' ')"
  [ "$order" = "shop-operator shophub shophub-discord " ]
  [[ "$output" == *"[1/3] shop-operator"*"installed"* ]]
  [[ "$output" == *"done: 3 installed, 0 upgraded, 0 unchanged"* ]]
}

@test "upgrade uses OCI url, exact version, namespace, values file, --reset-values and --wait" {
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  grep -q -- "upgrade --install shophub oci://ghcr.io/nikola031ue/charts/shophub --version 0.1.0 -n shophub --create-namespace -f clusters/local/shophub/values.yaml --reset-values --wait --timeout 5m" "$STUB_LOG"
}

@test "override removed from values.yaml -> upgraded with --reset-values (no stale values)" {
  all_deployed
  export HELM_VALUES_SHOPHUB='{"replicaCount":2}'
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"shophub "*"upgraded"* ]]
  grep '^helm upgrade --install shophub ' "$STUB_LOG" | grep -q -- '--reset-values'
}

@test "HELM_TIMEOUT is passed to helm" {
  HELM_TIMEOUT=9m run ./bring-up.sh
  [ "$status" -eq 0 ]
  grep -q -- "--timeout 9m" "$STUB_LOG"
}

# ---- idempotency (FR-019, SC-003) ----

@test "matching version, values and status -> unchanged, no upgrade" {
  all_deployed
  export HELM_VALUES_SHOP_OPERATOR='{}' HELM_VALUES_SHOPHUB='{}' HELM_VALUES_SHOPHUB_DISCORD='{}'
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  ! grep -q '^helm upgrade' "$STUB_LOG"
  [[ "$output" == *"done: 0 installed, 0 upgraded, 3 unchanged"* ]]
}

@test "empty values.yaml vs helm get values null -> unchanged (normalisation)" {
  all_deployed
  printf '# comments only\n' > clusters/local/shophub/values.yaml
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  ! grep -q '^helm upgrade' "$STUB_LOG"
  [[ "$output" == *"3 unchanged"* ]]
}

@test "values compared independent of key order" {
  all_deployed
  printf 'b: 2\na: 1\n' > clusters/local/shophub/values.yaml
  export HELM_VALUES_SHOPHUB='{"a":1,"b":2}'
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  ! grep -q '^helm upgrade' "$STUB_LOG"
}

@test "chart name containing hyphens: shop-operator-0.1.0 equals 0.1.0" {
  all_deployed
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  ! grep -q 'upgrade --install shop-operator' "$STUB_LOG"
}

@test "differing values -> only that release upgraded" {
  all_deployed
  echo 'replicaCount: 2' > clusters/local/shophub/values.yaml
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  [ "$(grep -c '^helm upgrade' "$STUB_LOG")" -eq 1 ]
  grep -q 'upgrade --install shophub ' "$STUB_LOG"
  [[ "$output" == *"done: 0 installed, 1 upgraded, 2 unchanged"* ]]
}

@test "different deployed version -> upgraded" {
  all_deployed
  export HELM_LIST_SHOPHUB="$(deployed shophub shophub-0.0.9)"
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  grep -q 'upgrade --install shophub ' "$STUB_LOG"
}

@test "failed release status -> upgraded" {
  all_deployed
  export HELM_LIST_SHOPHUB="$(deployed shophub shophub-0.1.0 failed)"
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  grep -q 'upgrade --install shophub ' "$STUB_LOG"
}

# ---- failures ----

@test "first release fails -> exit 1, later releases not attempted" {
  HELM_UPGRADE_FAIL_SHOP_OPERATOR=error run ./bring-up.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"shop-operator"* ]]
  ! grep -q 'upgrade --install shophub' "$STUB_LOG"
}

@test "chart version not found -> exit 6 naming release and version" {
  HELM_UPGRADE_FAIL_SHOPHUB=notfound run ./bring-up.sh
  [ "$status" -eq 6 ]
  [[ "$output" == *"shophub"* && "$output" == *"0.1.0"* ]]
  ! grep -q 'upgrade --install shophub-discord' "$STUB_LOG"
}

# ---- CRD wait (FR-023) ----

@test "no CRDs -> 'crds: none' and no kubectl wait" {
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"crds: none"* ]]
  ! grep -q '^kubectl.* wait' "$STUB_LOG"
}

@test "CRDs from show crds and from the manifest are both waited on" {
  export HELM_CRDS_SHOP_OPERATOR="$(crd shops.shophub.dev)"
  export HELM_MANIFEST_SHOP_OPERATOR="$(crd wallets.shophub.dev)"
  CRD_WAIT_TIMEOUT=7s run ./bring-up.sh
  [ "$status" -eq 0 ]
  grep -q 'wait --for=condition=Established crd/shops.shophub.dev --timeout=7s' "$STUB_LOG"
  grep -q 'wait --for=condition=Established crd/wallets.shophub.dev --timeout=7s' "$STUB_LOG"
}

@test "CRD wait happens before the next release is installed" {
  export HELM_CRDS_SHOP_OPERATOR="$(crd shops.shophub.dev)"
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  wait_line="$(grep -n 'crd/shops.shophub.dev' "$STUB_LOG" | cut -d: -f1)"
  next_line="$(grep -n 'upgrade --install shophub ' "$STUB_LOG" | cut -d: -f1)"
  (( wait_line < next_line ))
}

@test "CRD not Established in time -> exit 5 naming the CRD, next release not installed" {
  export HELM_CRDS_SHOP_OPERATOR="$(crd shops.shophub.dev)"
  KUBECTL_WAIT_FAIL=shops.shophub.dev run ./bring-up.sh
  [ "$status" -eq 5 ]
  [[ "$output" == *"shops.shophub.dev"* ]]
  ! grep -q 'upgrade --install shophub ' "$STUB_LOG"
}

# ---- Principle V ----

@test "never applies manifests with kubectl" {
  export HELM_CRDS_SHOP_OPERATOR="$(crd shops.shophub.dev)"
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  ! grep -E '^kubectl .*\b(apply|create|edit|delete|patch|replace)\b' "$STUB_LOG"
}

# ---- required hand-made Secrets (spec 004, exit 7) ----

with_required_secret() {
  cat >> clusters/local/cluster.yaml <<'YAML'
requiredSecrets:
  - name: shophub-tls
    namespace: traefik
    release: shophub
    help: |
      HELP-MARKER: create the TLS Secret with mkcert (README "Local HTTPS")
YAML
}

@test "required Secret present -> checked with --context, releases installed" {
  with_required_secret
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  grep -q '^kubectl get secret shophub-tls -n traefik -o name --context docker-desktop' "$STUB_LOG"
  [[ "$output" == *"done: 3 installed"* ]]
}

@test "required Secret missing -> exit 7 with help, before any release" {
  with_required_secret
  KUBECTL_SECRET_MISSING=shophub-tls run ./bring-up.sh
  [ "$status" -eq 7 ]
  [[ "$output" == *"HELP-MARKER"* ]]
  [[ "$output" == *"traefik/shophub-tls"* ]]
  ! grep -q '^helm upgrade' "$STUB_LOG"
}

@test "required Secret check fails for another reason -> exit 1 with kubectl's error" {
  with_required_secret
  KUBECTL_SECRET_ERROR=1 run ./bring-up.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"connection to the server was refused"* ]]
  [[ "$output" != *"HELP-MARKER"* ]]
  ! grep -q '^helm upgrade' "$STUB_LOG"
}

@test "no requiredSecrets -> no Secret lookup" {
  run ./bring-up.sh
  [ "$status" -eq 0 ]
  ! grep -q '^kubectl get secret' "$STUB_LOG"
}
