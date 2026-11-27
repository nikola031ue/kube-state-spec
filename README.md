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
        ├── cnpg/                 # CloudNativePG operator (upstream chart)
        │   ├── helm.yaml
        │   └── values.yaml
        ├── redis-operator/       # OT redis-operator (upstream chart)
        │   ├── helm.yaml
        │   └── values.yaml
        ├── traefik/              # entry point: HTTPS ingress controller (upstream chart)
        │   ├── helm.yaml
        │   └── values.yaml
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
under `.github/`, including the upstream chart allowlist `.github/upstream-charts.yaml`.

### Platform state only

This repository holds **platform** state: operators, CRDs, the ShopHub application,
observability and database operators, and RBAC. Resources that ShopHub users create — `Shop`,
`Wallet`, `DiscordChannel` — and what the shop-operator derives from them (database CRs, shop
workloads, Secrets) are **runtime state**: created through the Kubernetes API and **never** stored
here (Constitution Principle V). The single `shophub-discord` channel for platform/cluster alerts
is maintainer-owned platform state; it lives in `shop-operator-system`.

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
| `requiredSecrets` | optional: hand-made Secrets (`name`, `namespace`, `release`, `help`) that must exist before bring-up installs anything; never their contents |

**`helm.yaml`** — two Flux documents, so Flux can adopt them later unchanged:

| Document | Fields used by `bring-up.sh` | Rules |
|----------|-------------------------------|-------|
| `OCIRepository` (`source.toolkit.fluxcd.io/v1`) | `spec.url`, `spec.ref.tag` | URL under `oci://ghcr.io/nikola031ue/charts/`, **or** an exact url + version listed in `.github/upstream-charts.yaml`; tag is exact SemVer (no ranges, no `latest`) |
| `HelmRelease` (`helm.toolkit.fluxcd.io/v2`) | `spec.releaseName`, `spec.targetNamespace` | names equal the folder; `dependsOn` lists earlier releases; `valuesFrom` → ConfigMap `<folder>-values` |

**`values.yaml`** — plain Helm overrides (`{}` allowed). **Never** literal secrets: reference
Kubernetes Secrets by name (`existingSecret`, `…SecretName`). CI rejects secret-looking values
and images with a missing or `latest` tag.

**Image versions.** Where a release's `values.yaml` sets `image.tag` (for example
`clusters/local/shophub/values.yaml`), that tag is what runs: our charts (`shophub`, `shop-operator`) use
`image.tag | default .Chart.AppVersion`, so the chart's `appVersion` only applies when no tag is
set. Rolling out a new app version means changing `image.tag` here; bumping the chart's
`appVersion` alone changes nothing.

### Adding a release

1. Publish the chart from `helm-charts`.
2. Create `clusters/local/<release>/helm.yaml` (copy an existing one, change names, URL, tag,
   namespace, `dependsOn`) and `clusters/local/<release>/values.yaml`.
3. Add `<release>` to `releaseOrder` in `cluster.yaml` after its dependencies.

### Upstream charts

Charts we don't write (the database operators, the ingress controller) are used as published by their projects and are
allowed **only** at the exact versions in `.github/upstream-charts.yaml`:

| Release | Chart | Version |
|---------|-------|---------|
| `cnpg` | `oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg` | 0.29.2 (operator 1.30.2) |
| `redis-operator` | `oci://ghcr.io/ot-container-kit/charts/redis-operator` | 0.27.0 |
| `traefik` | `oci://ghcr.io/traefik/helm/traefik` | 42.3.1 (Traefik v3.7.17) |

To bump one, change the release's `helm.yaml` tag **and** its allowlist entry in the same PR; the
`schema` check fails otherwise.

### Local HTTPS

The `traefik` release is the cluster entry point (spec 004): HTTPS on `localhost:443` through
the Docker Desktop LoadBalancer, plain HTTP redirected permanently to HTTPS, IngressClass
`traefik` as the default. Hosts:

- `https://shophub.localhost`: ShopHub;
- `https://<shop>.shops.localhost`: each shop (Ingress created by the shop-operator).

`*.localhost` names resolve to 127.0.0.1 in browsers without any hosts-file entry. Its default
certificate is the Secret `shophub-tls` in namespace `traefik`. It is made **by hand once per
cluster** with [mkcert](https://github.com/FiloSottile/mkcert), so the browser trusts it and the
private key is never committed (like the Discord token). On Windows, install it with
`winget install FiloSottile.mkcert`.

```bash
mkcert -install    # one time per machine: trusts the local CA in the browser / Windows store
mkcert -cert-file shophub.pem -key-file shophub-key.pem shophub.localhost '*.shops.localhost'
kubectl create namespace traefik
kubectl create secret tls shophub-tls -n traefik --cert=shophub.pem --key=shophub-key.pem
rm shophub.pem shophub-key.pem
```

`bring-up.sh` checks that this Secret exists before installing anything (it is listed in
`cluster.yaml` `requiredSecrets`). If it is missing, the script prints these steps and stops
with exit code 7. The mkcert CA key stays on your machine (`mkcert -CAROOT`).

Browsers trust the certificate after `mkcert -install`. **`curl` in Git Bash on Windows** uses the
Windows TLS stack, which can't check revocation for a mkcert certificate and fails with
`CRYPT_E_NO_REVOCATION_CHECK`; add `--ssl-no-revoke` (the certificate is still verified).

The release also creates a headless Service, `traefik-proxies`, that resolves to the Traefik pod
IPs. ShopHub trusts forwarded client addresses only from those IPs.

### Discord

The shop-operator creates Discord channels for `DiscordChannel` resources (including
`shophub-discord`'s `platform-alerts` in `shop-operator-system`). It needs, once per cluster:

1. the project server ID in `clusters/local/shop-operator/values.yaml` → `discord.guildID`
   (not a secret), and
2. the bot token in a Secret — a **manual step** (spec 002 plan, Complexity
   Tracking), because the token must never be committed:

   ```bash
   kubectl create namespace shop-operator-system   # on an empty cluster; bring-up reuses it
   kubectl create secret generic shop-operator-discord -n shop-operator-system \
     --from-literal=token="$DISCORD_BOT_TOKEN"
   ```

   `bring-up.sh` installs with `helm --create-namespace`, which leaves an existing namespace as
   it is, so creating it first is safe (the same as `traefik` for the TLS Secret).

Without them everything still installs; DiscordChannels report `DiscordCredentialsMissing` and
the operator re-checks the token every minute. Bot setup: shop-operator README.

**Moving from shop-operator chart 0.3.x (one time).** Chart 0.4.0 watches only `shops` and its
own namespace, so `shophub-discord` moves from `shophub` to `shop-operator-system`. A Helm
release can't change namespace, and `bring-up.sh` never deletes, so before running bring-up
with chart 0.4.0, while operator 0.2.1 still runs (its finalizer removes the old Discord channel):

```bash
kubectl delete discordchannel platform-alerts -n shophub --wait --timeout=2m
helm uninstall shophub-discord -n shophub
./bring-up.sh
```

### Payments

The shop-operator watches Sepolia for mUSDT payments to every Wallet (spec 005). The token
address is public and sits in `clusters/local/shop-operator/values.yaml` → `payments.tokenAddress`.
The provider endpoint URL carries an API key, so it goes in a Secret — a **manual step**, once
per cluster:

```bash
kubectl create namespace shop-operator-system   # on an empty cluster; bring-up reuses it
read -rs RPC_URL   # paste the endpoint, nothing is echoed
kubectl create secret generic shop-operator-rpc -n shop-operator-system --from-literal=url="$RPC_URL"
unset RPC_URL
```

Without it everything still installs; Wallets report `PaymentsWatching=False` with reason
`RPCCredentialsMissing` and shops refuse checkout.

**Version pairing.** shop-operator chart 0.5.0 adds an admission policy that refuses deleting a
Shop unless ShopHub marked it (`shophub.io/delete-requested`), which ShopHub does from 0.3.0 on.
Roll out ShopHub 0.3.0 before moving the operator chart to 0.5.0; the `pairing` CI check refuses
the other order. A Shop is then deleted through the ShopHub panel or API, not `kubectl delete`.

## Bring-up

Brings an **empty** local cluster to the state in this repository. Nothing else needs to be
cloned. The only manual steps are the hand-made Secrets: the TLS certificate (required,
[Local HTTPS](#local-https)) and the Discord token (optional, [Discord](#discord)).

### Prerequisites

- Docker Desktop with Kubernetes enabled (kube context `docker-desktop`)
- `mkcert`, and the `shophub-tls` Secret ([Local HTTPS](#local-https))
- `helm` ≥ 3.8, `yq` v4 ([mikefarah/yq](https://github.com/mikefarah/yq)), `jq`, `kubectl`
- Windows: run from **Git Bash**. Tools via
  `winget install Helm.Helm MikeFarah.yq jqlang.jq` (kubectl ships with Docker Desktop).

### Run

```bash
kubectl config use-context docker-desktop
./bring-up.sh            # cluster "local" by default
```

It first checks that every Secret in `requiredSecrets` exists (exit 7 with the creation steps
if not). Then, for each release in `releaseOrder`, the script:

1. installs or upgrades it with `helm upgrade --install --reset-values --wait` from the pinned OCI chart and
   its `values.yaml` — or prints `unchanged` and skips it if the deployed chart version, values
   and status already match;
2. waits for every CRD the release provides to be `Established` before the next release.

It refuses to run against any kube context other than the one in `cluster.yaml`, and it never
runs `kubectl apply/create/edit/delete` (Principle V). It only reads whether required Secrets
exist; it never reads their data.

Expected output on an empty cluster:

```text
[cluster] local (context docker-desktop)
[1/6] cnpg             0.29.2  cnpg-system            installed
[1/6] cnpg             crds: backups.postgresql.cnpg.io,…,subscriptions.postgresql.cnpg.io Established
[2/6] redis-operator   0.27.0  redis-operator         installed
[2/6] redis-operator   crds: redis.redis.redis.opstreelabs.in,… Established
[3/6] traefik          42.3.1  traefik                installed
[3/6] traefik          crds: accesscontrolpolicies.hub.traefik.io,…,uplinks.hub.traefik.io Established
[4/6] shop-operator    0.4.0   shop-operator-system   installed
[4/6] shop-operator    crds: discordchannels.shophub.io,shops.shophub.io,wallets.shophub.io Established
[5/6] shophub          0.2.1   shophub                installed
[5/6] shophub          crds: none
[6/6] shophub-discord  0.2.0   shop-operator-system   installed
[6/6] shophub-discord  crds: none
...
done: 6 installed, 0 upgraded, 0 unchanged
```

Running it again with no changes prints `done: 0 installed, 0 upgraded, 6 unchanged`. After
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
| 7 | a Secret listed in `cluster.yaml` `requiredSecrets` is missing (creation steps printed; nothing installed) |

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
| `schema` | `cluster.yaml` / `helm.yaml` / `values.yaml` rules; `releaseOrder` vs `dependsOn`; chart source = our registry or the upstream allowlist |
| `charts-exist` | every pinned chart version is pullable anonymously |
| `render` | every release renders with its `values.yaml`; no missing/`latest` image tags |
| `pairing` | shop-operator chart ≥ 0.5.0 (Shop delete guard) only with ShopHub `image.tag` ≥ 0.3.0 |
| `secrets-scan` | no literal secrets in `values.yaml` |
| `unit` | `bring-up.sh` tests with stubbed `helm`/`kubectl` |
| `e2e` | kind cluster: missing TLS Secret stops with exit 7; bring-up twice, second run all `unchanged`; Traefik redirect, default certificate and `traefik-proxies` DNS; wrong context refused. kind has no LoadBalancer, so CI runs Traefik as NodePort and uses a throwaway self-signed Secret |

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
