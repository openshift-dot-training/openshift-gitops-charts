{{/*
Validate groups.yaml: every component referenced by a group (or common) must
exist in the catalog; every group needs at least one filter; a group's
clusterSets must be bound (acm.clusterSets).
*/}}
{{- define "platform.validate" -}}
{{- $v := .Values -}}
{{- $components := $v.components | default dict -}}
{{- range $c := $v.common | default list -}}
{{- if not (hasKey $components $c) -}}
{{- fail (printf "groups.yaml: common component %q is not defined in the catalog (components)" $c) -}}
{{- end -}}
{{- end -}}
{{- range $g, $grp := $v.groups | default dict -}}
{{- if not (or $grp.labelSelector $grp.claimSelector $grp.clusterSets) -}}
{{- fail (printf "groups.yaml: group %q has no filter - set labelSelector, claimSelector and/or clusterSets" $g) -}}
{{- end -}}
{{- range $s := $grp.clusterSets | default list -}}
{{- if not (has $s $v.acm.clusterSets) -}}
{{- fail (printf "groups.yaml: group %q uses clusterSet %q, which is not in acm.clusterSets (needs a ManagedClusterSetBinding)" $g $s) -}}
{{- end -}}
{{- end -}}
{{- range $c := $grp.components | default list -}}
{{- if not (hasKey $components $c) -}}
{{- fail (printf "groups.yaml: component %q (group %q) is not defined in the catalog (components)" $c $g) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Is a catalog component enabled? (absent "enabled" means true)
Usage: include "platform.enabled" $component  -> "true" / ""
*/}}
{{- define "platform.enabled" -}}
{{- if or (not (hasKey . "enabled")) .enabled -}}true{{- end -}}
{{- end -}}

{{/*
Groups that place a component, as a JSON list: every group for a common
component, else the groups listing it.
Usage: include "platform.groupsOf" (dict "name" $name "root" $) | fromJsonArray
*/}}
{{- define "platform.groupsOf" -}}
{{- $name := .name -}}
{{- $v := .root.Values -}}
{{- $out := list -}}
{{- $common := has $name ($v.common | default list) -}}
{{- range $g, $grp := $v.groups | default dict -}}
{{- if or $common (has $name ($grp.components | default list)) -}}
{{- $out = append $out $g -}}
{{- end -}}
{{- end -}}
{{- $out | sortAlpha | toJson -}}
{{- end -}}

{{/*
ACM Placement spec for one component, shared by the Placement the
ApplicationSet reads (Argo CD namespace) and the one its health Policy binds
(policy namespace), so both always select the same clusters.

Predicates are OR-ed:
  - one per group placing the component: the group's labelSelector (+ its
    clusterSets, as the clusterset label) and claimSelector, minus clusters
    labelled <componentPrefix><name>=enabled|disabled
  - clusters labelled <componentPrefix><name>=enabled (per-cluster opt-in)
Usage: include "platform.placementSpec" (dict "name" $name "root" $) | fromYaml
*/}}
{{- define "platform.placementSpec" -}}
{{- $name := .name -}}
{{- $v := .root.Values -}}
{{- $compLabel := printf "%s%s" $v.labels.componentPrefix $name -}}
{{- $preds := list -}}
{{- range $g := include "platform.groupsOf" . | fromJsonArray -}}
{{- $grp := index $v.groups $g -}}
{{- $ls := deepCopy ($grp.labelSelector | default dict) -}}
{{- $exprs := concat ($ls.matchExpressions | default list) (list (dict "key" $compLabel "operator" "NotIn" "values" (list "enabled" "disabled"))) -}}
{{- with $grp.clusterSets -}}
{{- $exprs = append $exprs (dict "key" "cluster.open-cluster-management.io/clusterset" "operator" "In" "values" .) -}}
{{- end -}}
{{- $_ := set $ls "matchExpressions" $exprs -}}
{{- $sel := dict "labelSelector" $ls -}}
{{- with $grp.claimSelector -}}
{{- $_ := set $sel "claimSelector" . -}}
{{- end -}}
{{- $preds = append $preds (dict "requiredClusterSelector" $sel) -}}
{{- end -}}
{{- $preds = append $preds (dict "requiredClusterSelector" (dict "labelSelector" (dict "matchLabels" (dict $compLabel "enabled")))) -}}
{{- toYaml (dict "clusterSets" $v.acm.clusterSets "predicates" $preds "tolerations" ($v.acm.tolerations | default list)) -}}
{{- end -}}

{{/*
Config-repository path with placeholders filled per cluster:
  {component}    the component name
  {cluster}      the cluster name (ManagedCluster = Argo CD cluster)
  {label:<key>}  the value of the cluster's label <key> ("_none" when unset),
                 e.g. {label:openshiftVersion-major-minor}, set by ACM
Usage: include "platform.path" (dict "path" $p "name" $component "root" $)
*/}}
{{- define "platform.path" -}}
{{- $p := .path | replace "{component}" .name | replace "{cluster}" "{{ .name }}" -}}
{{- regexReplaceAll "\\{label:([^}]+)\\}" $p "{{ index .metadata.labels \"${1}\" | default \"_none\" }}" -}}
{{- end -}}

{{/* charts revision: the cluster's chartsRevision label, else repos.charts.version */}}
{{- define "platform.chartsRevision" -}}
{{- printf "{{ index .metadata.labels %q | default %q }}" .Values.labels.chartsRevision .Values.repos.charts.version -}}
{{- end -}}

{{/* config revision: the cluster's configRevision label, else repos.config.revision */}}
{{- define "platform.configRevision" -}}
{{- printf "{{ index .metadata.labels %q | default %q }}" .Values.labels.configRevision .Values.repos.config.revision -}}
{{- end -}}
