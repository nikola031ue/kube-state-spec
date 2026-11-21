# kube-state

Desired state of the ShopHub Kubernetes clusters, laid out exactly as required by
**Requirement 5.3**. Charts come from the
[`helm-charts`](https://github.com/nikola031ue/helm-charts-spec) repository, published to
`oci://ghcr.io/nikola031ue/charts`.

## Repository layout

```text
kube-state
├── README.md
├── bring-up.sh
└── clusters/
    └── local/
        ├── cluster.yaml          # cluster metadata (not a Kubernetes object)
        ├── shop-operator/
        │   ├── helm.yaml         # chart in OCI format + exact version, release, namespace
        │   └── values.yaml       # value overrides
        ├── shophub/
        │   ├── helm.yaml
        │   └── values.yaml
        └── shophub-discord/
            ├── helm.yaml
            └── values.yaml
```

The layout is immutable (Constitution Principle I) and enforced by the `layout` CI check:
every release folder contains **exactly** `helm.yaml` and `values.yaml`. CI tooling lives only
under `.github/`.

### Platform state only

This repository holds **platform** state: operators, CRDs, the ShopHub application,
observability and database operators, and RBAC. Resources that ShopHub users create — `Shop`,
`Wallet`, `DiscordChannel` and database CRs — are **runtime state** created by the ShopHub backend
through the Kubernetes API and are **never** stored here (Constitution Principle V). The single
`shophub-discord` channel for platform/cluster alerts is maintainer-owned platform state.

## File reference

Full schema: `shophub-specs/specs/001-iac-foundation/contracts/kube-state-files.md`.

**`cluster.yaml`**

| Field | Meaning |
|-------|---------|
| `name` | equals the folder name (`local`) |
| `context` | kube context bring-up must run against (`docker-desktop`) |
| `distribution` | `docker-desktop` |
| `kubernetesVersion` | informational |
| `releaseOrder` | every release folder exactly once, dependencies first |

**`helm.yaml`** — two Flux documents, so Flux can adopt them later unchanged:

| Document | Fields used by `bring-up.sh` | Rules |
|----------|-------------------------------|-------|
| `OCIRepository` (`source.toolkit.fluxcd.io/v1`) | `spec.url`, `spec.ref.tag` | URL under `oci://ghcr.io/nikola031ue/charts/`; tag is exact SemVer (no ranges, no `latest`) |
| `HelmRelease` (`helm.toolkit.fluxcd.io/v2`) | `spec.releaseName`, `spec.targetNamespace` | names equal the folder; `dependsOn` lists earlier releases; `valuesFrom` → ConfigMap `<folder>-values` |

**`values.yaml`** — plain Helm overrides (`{}` allowed). **Never** literal secrets: reference
Kubernetes Secrets by name (`existingSecret`, `…SecretName`). CI rejects secret-looking values
and images with a missing or `latest` tag.

### Adding a release

1. Publish the chart from `helm-charts`.
2. Create `clusters/local/<release>/helm.yaml` (copy an existing one, change names, URL, tag,
   namespace, `dependsOn`) and `clusters/local/<release>/values.yaml`.
3. Add `<release>` to `releaseOrder` in `cluster.yaml` after its dependencies.

## Bring-up

Brings an **empty** local cluster to the state in this repository. Nothing else needs to be
cloned.

### Prerequisites

- Docker Desktop with Kubernetes enabled (kube context `docker-desktop`)
- `helm` ≥ 3.8, `yq` v4 ([mikefarah/yq](https://github.com/mikefarah/yq)), `jq`, `kubectl`
- Windows: run from **Git Bash**. Tools via
  `winget install Helm.Helm MikeFarah.yq jqlang.jq` (kubectl ships with Docker Desktop).

### Run

```bash
kubectl config use-context docker-desktop
./bring-up.sh            # cluster "local" by default
```

For each release in `releaseOrder` the script:

1. installs or upgrades it with `helm upgrade --install --reset-values --wait` from the pinned OCI chart and
   its `values.yaml` — or prints `unchanged` and skips it if the deployed chart version, values
   and status already match;
2. waits for every CRD the release provides to be `Established` before the next release.

It refuses to run against any kube context other than the one in `cluster.yaml`, and it never
runs `kubectl apply/create/edit/delete` (Principle V).

Expected output on an empty cluster:

```text
[cluster] local (context docker-desktop)
[1/3] shop-operator    0.1.0   shop-operator-system   installed
[1/3] shop-operator    crds: none
[2/3] shophub          0.1.0   shophub                installed
[2/3] shophub          crds: none
[3/3] shophub-discord  0.1.0   shophub                installed
[3/3] shophub-discord  crds: none
...
done: 3 installed, 0 upgraded, 0 unchanged
```

Running it again with no changes prints `done: 0 installed, 0 upgraded, 3 unchanged`. After
changing a tag or a value, only the affected release is upgraded.

| Env var | Default | Meaning |
|---------|---------|---------|
| `HELM_TIMEOUT` | `5m` | `--timeout` for each release |
| `CRD_WAIT_TIMEOUT` | `120s` | per-CRD wait for `Established` |

| Exit code | Meaning |
|-----------|---------|
| 0 | all releases installed / upgraded / unchanged |
| 1 | a release failed (later releases not attempted) |
| 2 | required tool missing or too old |
| 3 | `cluster.yaml` / `helm.yaml` / `values.yaml` missing or invalid (all release folders are validated before any install) |
| 4 | current kube context does not match `cluster.yaml` |
| 5 | a CRD did not become `Established` in time |
| 6 | chart version not found or registry unreachable |

### Reset to an empty cluster

Docker Desktop → Settings → Kubernetes → **Reset Kubernetes Cluster**, then run `./bring-up.sh`.

### GitOps later

The release folders are already valid Flux objects. Adopting Flux later adds a
`clusters/local/kustomization.yaml` that generates the `<release>-values` ConfigMaps; the release
folders stay unchanged (see the plan's risk note about where Flux bootstraps itself).

## CI checks

| Check | What |
|-------|------|
| `layout` | 5.3 tree; release folders contain exactly `helm.yaml` + `values.yaml` |
| `schema` | `cluster.yaml` / `helm.yaml` / `values.yaml` rules; `releaseOrder` vs `dependsOn` |
| `charts-exist` | every pinned chart version is pullable anonymously |
| `render` | every release renders with its `values.yaml`; no missing/`latest` image tags |
| `secrets-scan` | no literal secrets in `values.yaml` |
| `unit` | `bring-up.sh` tests with stubbed `helm`/`kubectl` |
| `e2e` | kind cluster: bring-up twice, second run all `unchanged`; wrong context refused |

## Branch protection

`main` is protected (trunk-based, solo developer — Constitution deviation D-1: no required
approvals; self-review + required CI instead):

```bash
gh api -X PUT repos/nikola031ue/kube-state-spec/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": { "strict": true,
    "contexts": ["layout", "schema", "charts-exist", "render", "secrets-scan", "unit", "e2e"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

## Local validation

```bash
bash .github/scripts/check-layout.sh && bash .github/scripts/check-schema.sh
bash .github/scripts/scan-secrets.sh clusters/*/*/values.yaml
bats .github/tests/
```
