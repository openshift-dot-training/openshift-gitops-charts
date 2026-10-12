# OpenShift GitOps charts

Generic Helm charts for installing OLM operators at **exact versions** with
`installPlanApproval: Manual`, and for the hub catalog that places them on
groups of ACM managed clusters. They hold no environment data: what runs where,
and which versions, lives in the config repository, openshift-gitops-config.

| Chart | Installed on | What it renders |
|---|---|---|
| `charts/olm-operator` | every managed cluster, once per operator (by an ApplicationSet) | Namespace, OperatorGroup, Subscription pinned to an exact CSV, the InstallPlan approver(s), operands (`extraObjects`) |
| `charts/platform-catalog` | the ACM hub (root Application) | one ACM Placement + ApplicationSet (+ health Policy) per component; groups are Placement filters, from the config repository's `catalog.yaml` and `groups.yaml` |

## Releases

The config repository pins this repository by tag
(`repos.charts.version` in its `catalog.yaml`, `v0.1.0` today). A cluster can
test another revision with the ManagedCluster label `chartsRevision=<tag or
branch>`. Release flow:

1. PR to `main`. CI renders every chart against the fixtures in `tests/`.
2. Merge, then tag `vX.Y.Z` and bump the `version` in each changed `Chart.yaml`.
3. In the config repository, canary the new tag on one cluster with
   `chartsRevision`, then raise `repos.charts.version`.

## olm-operator

Values come from the config repository's layers, in this order:

1. `components/versions.yaml`
2. `components/<name>/values.yaml`
3. `group-values/<group>/…`
4. `clusters/<cluster>/…`

All fields are documented in `charts/olm-operator/values.yaml`:

| Value | Purpose |
|---|---|
| `versions.<release>` | `channel`, `version`, `csv`, `dependencies`, `installPlanApproval`, extra operand keys |
| `subscription.*` | package `name`, `source`, `csvFormat` (CSV name from a version), fallback `dependencies` |
| `operatorGroup.*`, `namespace.*` | install mode and namespace labels |
| `approver.*` | `image` (mirrored ose-cli), `timeoutSeconds`, `extra` approvers |
| `extraObjects` | operands applied at wave 10, rendered with `tpl` |

## InstallPlan approver

**The problem.** With `installPlanApproval: Manual`, OLM never installs or
upgrades on its own. When a version is available, it creates an
**InstallPlan** with `spec.approved: false` and waits:

```
$ oc get installplan -n openshift-logging
NAME            CSV                      APPROVAL   APPROVED
install-7x2kq   cluster-logging.v6.1.4   Manual     false     <- waiting for approval
```

Argo CD cannot approve it: InstallPlans are not in Git, and OLM creates them
with generated names. With Manual approval and Argo CD alone, nothing would
ever install. Someone would have to approve every plan by hand, on every
cluster.

**The approver** does that approval, but only for the version written in Git.
The `olm-operator` chart renders it in every operator namespace (one per
operator) whenever the approval mode is Manual
(`templates/approver.yaml`):

- a ServiceAccount, Role and RoleBinding that can read Subscriptions and CSVs
  and patch InstallPlans in that namespace only
- a Job (an Argo CD **Sync hook**) running `oc` from the mirrored `ose-cli`
  image. It is re-created on every sync of that Application.

The Job's logic:

```
want = exact CSV from versions.<component>          e.g. cluster-logging.v6.1.4

loop until timeout (approver.timeoutSeconds, default 900s):
  1. want installed and Succeeded?                  -> exit OK (steady state: ~1s)
  2. pending InstallPlan containing want, and nothing else except declared
     dependencies?                                  -> approve it
  3. pending InstallPlan for another version        -> SKIP, log it
     pending InstallPlan that also carries another operator -> REFUSE, log it
  4. sleep approver.pollSeconds
timeout                                             -> Job fails -> Argo CD sync Failed
```

It never approves anything other than the version in Git. The worst case is
that it approves nothing and the sync turns red, with the reason in the Job
log.

**Where it runs in a sync.** Argo CD finishes each wave before starting the
next:

```
wave -10  Namespace
wave  -6  approver ServiceAccount / Role / RoleBinding
wave  -5  OperatorGroup, Subscription (Manual, startingCSV = want)
              OLM resolves and creates an InstallPlan (approved: false)
wave  -4  approver Job: approves the matching plan, waits for CSV Succeeded
wave  10  operands (extraObjects): LokiStack, StorageCluster, ...
```

The operands are therefore only applied once the operator runs exactly the
version from Git. Argo CD's built-in Subscription health check reports a
pending plan as Healthy when approval is Manual, so the Subscription does not
block the wave.

**New cluster.**

1. The Subscription is created with `startingCSV: cluster-logging.v6.1.4`.
2. OLM creates a pending plan for that CSV.
3. The Job approves it and waits for `Succeeded`.
4. The operands sync.

**Upgrade, e.g. 6.1.4 → 6.1.5.**

1. Mirror 6.1.5 into the disconnected registry. OLM creates a pending plan for
   it, and nothing happens because Git still says 6.1.4.
2. Change `version` to `6.1.5` in the group's `versions.yaml` through a PR (or
   in one cluster's `clusters/<cluster>/main-values.yaml` first, as a canary).
3. Argo CD syncs and the Job runs. It finds 6.1.4 installed, approves the 6.1.5
   plan, and waits until `cluster-logging.v6.1.5` is `Succeeded`.

**When it refuses.** The Job log says why, and the sync shows Failed:

| Situation | Result |
|---|---|
| OLM proposes a newer version than Git, e.g. the mirror has 6.1.6 and Git says 6.1.5 | SKIP, then timeout |
| Git names a version that is not mirrored, or not in the subscribed channel | no matching plan, timeout |
| The plan also contains another operator's CSV | REFUSE, then timeout |
| Git asks for an older version than the installed one (OLM cannot downgrade) | timeout, log shows the installed CSV |

OLM upgrades to the **newest** version in the channel that can replace the
installed one. Red Hat operators declare that a release replaces all older
ones, so OLM goes straight to the newest. So the version in Git must be the
newest one in the mirrored channel. Mirroring exactly what is needed
(`minVersion` = `maxVersion` per package in oc-mirror) gives this
automatically.

**Catalogs.** The approver works with **any OLM catalog**: `redhat-operators`,
`certified-operators`, `community-operators`, `redhat-marketplace`, and
mirrored or custom catalogs (oc-mirror output, internal catalogs). It only
reads `InstallPlan.spec.clusterServiceVersionNames`, which OLM fills the same
way whatever catalog the bundle came from. It does not apply to OLM v1
(`ClusterExtension`), which has no InstallPlans.

**One InstallPlan per operator.** OLM resolves all Subscriptions in a
namespace as one unit. A single InstallPlan can therefore carry CSVs of
several operators in the same namespace, and approving it would upgrade all of
them. A pending Manual plan also blocks the other operators in that
namespace. There is no OLM setting to split plans inside a namespace. The
only reliable way is **one operator per namespace, with its own
OperatorGroup**. This repo enforces that in three places:

- every component installs into its own namespace, with its own OperatorGroup
- the config repository's `scripts/validate.sh` fails if two components share an operator namespace
- the Job refuses any plan containing a CSV that is neither the wanted one nor
  listed in `subscription.dependencies`. Use that list for operators that
  legitimately install together, e.g. ODF with `ocs-operator`, `mcg-operator`
  and others (the config repository's `components/odf/values.yaml`).

Do not install Manual-approval operators into the shared `openshift-operators`
namespace.

**Operators that install sub-operators.** It depends on how the operator
installs them:

| Pattern | Examples | What to do |
|---|---|---|
| One bundle, one CSV. The operator deploys its sub-components itself. | OpenShift Virtualization, Logging, Loki, ACS | nothing |
| OLM dependencies, in the **same InstallPlan** | `web-terminal` → `devworkspace-operator` | generate `versions.<component>.dependencies` (config repository: olm-upgrade-analyzer export or `scripts/olm-dependencies.py`) |
| The operator creates **another Subscription** at runtime, in the same namespace | ODF 4.17+: `odf-operator` creates `odf-dependencies`, whose InstallPlan brings in the 8 ODF sub-operators | `approver.extra` with `csvFromMain` + `dependenciesKey` (config repository: `components/odf/values.yaml`) |
| The operator creates **another Subscription** at runtime, in another namespace | ACM, which creates `multicluster-engine` | `approver.extra` (below) |

**Real CSV names do not follow one pattern.** Examples from the Red Hat
catalogs: `kubernetes-nmstate-operator.4.20.0-202609291520` (no `v`),
`custom-metrics-autoscaler.v2.15.1-6` (a prefix other than the package name)
and `odf-operator.v4.18.3-rhodf`. Prefer an exact `csv:` in the versions files,
which olm-upgrade-analyzer writes, over `csvFormat`. Exact dependency CSVs work
for every name. The prefix fallback in `subscription.dependencies` only works
for `<name>.v<version>` CSVs.

**Runtime Subscriptions: `approver.extra`.** Some operators create a
Subscription themselves, in a namespace this chart does not watch, and
nothing in Git describes it. For ACM, the config repository's
`components/acm/values.yaml` does three
things:

- **Pins MCE in the MultiClusterHub.** The
  `installer.open-cluster-management.io/mce-subscription-spec` annotation sets
  the MCE Subscription to Manual approval, the `mceChannel` channel and
  `startingCSV`.
- **Pins ACM and MCE together:** `versions.acm` holds `version` +
  `mceVersion` (ACM 2.12 ↔ MCE 2.7).
- **Adds a second approver** in `multicluster-engine`
  (`approver.extra`). It runs at wave 20/21, after the MultiClusterHub (wave
  10) that triggers the MCE Subscription, and approves only
  `multicluster-engine.v<mceVersion>`.

```yaml
approver:
  extra:
    - namespace: multicluster-engine
      subscription: multicluster-engine
      versionKey: mceVersion          # versions.acm.mceVersion
      csvFormat: multicluster-engine.v%s
      createNamespace: true
```

ACM is a hub-only component and is not in any group. Opt a hub in with
`component.platform/acm=enabled`. Managing the ACM of the hub that runs this
GitOps means it upgrades itself, so canary on a non-production hub first.

**Mirroring the approver image.** Add the `ose-cli` image to the oc-mirror
ImageSetConfiguration. Keep its tag within ±1 minor of the clusters'
OpenShift version, and set the same reference in
the config repository's `components/versions.yaml` → `approver.image`. A group or a cluster can
override it like any other value.

```yaml
# ImageSetConfiguration (oc-mirror v2)
mirror:
  additionalImages:
    - name: registry.redhat.io/openshift4/ose-cli-rhel9:v4.18
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.18
      packages:
        - name: cluster-logging
          channels:
            - name: stable-6.1
              minVersion: 6.1.4
              maxVersion: 6.1.4
```

The cluster's ImageDigestMirrorSet / ImageTagMirrorSet (generated by oc-mirror)
redirects the `registry.redhat.io` reference to the mirror registry. If your
clusters do not use mirror sets, put the mirror registry path in
`approver.image` instead.

## platform-catalog

Generic hub chart. Clusters are selected by **ACM Placements**, not by a
custom label convention. Inputs come from the config repository:
`catalog.yaml` (components, repositories) and `groups.yaml`.

**Groups are ACM Placement filters.** Each group sets any combination of:

| Filter | Example |
|---|---|
| `clusterSets` | `[prod]`: must be in `acm.clusterSets` (bound to the namespaces) |
| `labelSelector` | your labels (`platform/group: group-a`) or labels ACM sets on every cluster, such as `openshiftVersion-major-minor`, `cloud`, `vendor`, `name` |
| `claimSelector` | ClusterClaims such as `platform.open-cluster-management.io`, `region.open-cluster-management.io` |

A group lists its `components`. Components in `common` are placed by every
group. A group without any filter is refused, because it would select every
cluster.

**Per component** the chart renders the following:

- An **ACM Placement** in the Argo CD namespace. It has one predicate per group
  placing the component, and the predicates are OR-ed. Each group predicate
  excludes clusters labelled `component.platform/<name>=enabled|disabled`. A
  last predicate selects clusters labelled `component.platform/<name>=enabled`,
  the per-cluster opt-in. Clusters marked unreachable or unavailable are
  tolerated, so an outage does not delete their Applications.
- An **ApplicationSet**. A `merge` generator takes the clusters from that
  Placement's decisions (`clusterDecisionResource`, ConfigMap `acm-placement`)
  and adds each cluster's labels from the `clusters` generator.
- A **health Policy** (OperatorPolicy, inform), bound to an identical Placement
  in the policy namespace. ACM governance and Argo CD always see the same
  clusters.

**Values per cluster.** Each generated Application is multi-source.

- **Values** come from the config repository at the `configRevision` label
  (default `main`), through `valueFiles`. Paths use these placeholders:
  - `{component}`;
  - `{cluster}`, the ManagedCluster name;
  - `{label:<key>}`, any cluster label. For example,
    `ocp/{label:openshiftVersion-major-minor}/versions.yaml` picks the versions
    of the operators pinned to the OpenShift release reported by ACM.
- **The chart** comes from this repository at the `chartsRevision` label
  (default `repos.charts.version`), or from a component's own `repoURL`.

**Hub prerequisites.** The config repository's `bootstrap/` creates the
following:

- the `acm-placement` ConfigMap;
- read access to `placementdecisions` for the ApplicationSet controller;
- a ManagedClusterSetBinding for every set in `acm.clusterSets`, in both
  namespaces;
- the GitOpsCluster, which registers the clusters in Argo CD.

All fields are documented in `charts/platform-catalog/values.yaml`.

## Tests and hooks

```bash
git config core.hooksPath githooks     # once per clone
scripts/validate.sh                    # what the pre-commit hook and CI run
```

`scripts/validate.sh` runs these checks:

- `helm lint` on every chart.
- **Fixtures.** Each file in `tests/<chart>/` is rendered. Every
  `# expect: <yq expression>` line in it must be true on the array of rendered
  documents, and the `fail-*` fixtures must fail to render.
- **`tests/approver-sim.sh`.** Runs the approver Job's real script against a
  fake `oc`, covering install, steady state, a newer plan than Git, a mixed
  plan, and exact or prefix dependencies.

`scripts/check-sensitive.sh` blocks credentials, internal hostnames and IP
addresses. Everything here uses placeholders (`example.com`, `CHANGE-ME`).

## License

Apache License 2.0. See `LICENSE`.
