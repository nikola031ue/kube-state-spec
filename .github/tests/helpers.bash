# Shared fixture builder for kube-state bats tests.

# make_fixture ROOT — writes a valid kube-state tree for cluster "local".
make_fixture() {
  local root="$1" c="$1/clusters/local"
  mkdir -p "$c"
  touch "$root/README.md" "$root/bring-up.sh"
  mkdir -p "$root/.github"
  cat > "$root/.github/upstream-charts.yaml" <<'EOF'
charts:
  - url: oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg
    version: 0.29.2
EOF
  cat > "$c/cluster.yaml" <<'EOF'
name: local
context: docker-desktop
distribution: docker-desktop
kubernetesVersion: "1.31"
releaseOrder:
  - shop-operator
  - shophub
  - shophub-discord
EOF
  write_release "$c" shop-operator shop-operator-system ""
  write_release "$c" shophub shophub "shop-operator"
  write_release "$c" shophub-discord shophub "shophub"
}

# write_release CLUSTER_DIR NAME NAMESPACE DEPENDS_ON [TAG] [URL]
write_release() {
  local c="$1" name="$2" ns="$3" dep="$4" tag="${5:-0.1.0}"
  local url="${6:-oci://ghcr.io/nikola031ue/charts/$name}"
  mkdir -p "$c/$name"
  local deps=""
  if [[ -n "$dep" ]]; then
    deps=$'  dependsOn:\n    - name: '"$dep"
  fi
  cat > "$c/$name/helm.yaml" <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: $name
  namespace: flux-system
spec:
  interval: 10m
  url: $url
  ref:
    tag: "$tag"
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $name
  namespace: flux-system
spec:
  interval: 10m
  releaseName: $name
  targetNamespace: $ns
  install:
    createNamespace: true
  chartRef:
    kind: OCIRepository
    name: $name
$deps
  valuesFrom:
    - kind: ConfigMap
      name: $name-values
      valuesKey: values.yaml
EOF
  echo '{}' > "$c/$name/values.yaml"
}
