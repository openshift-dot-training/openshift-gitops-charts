{{/*
Validate groups.yaml: every component referenced by a group (or common) must
exist in the catalog.
*/}}
{{- define "platform.validate" -}}
{{- $components := .Values.components | default dict -}}
{{- range $c := .Values.common | default list -}}
{{- if not (hasKey $components $c) -}}
{{- fail (printf "groups.yaml: common component %q is not defined in values.components" $c) -}}
{{- end -}}
{{- end -}}
{{- range $g, $list := .Values.groups | default dict -}}
{{- range $c := $list -}}
{{- if not (hasKey $components $c) -}}
{{- fail (printf "groups.yaml: component %q (group %q) is not defined in values.components" $c $g) -}}
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
Cluster selection for one component, shared by the ApplicationSet (Argo CD
cluster generator, matching Argo cluster-secret labels) and the Placement (ACM,
matching ManagedCluster labels), so both always target the same clusters.

Returns YAML:
  byGroup: <labelSelector>   # only if the component is common or in >=1 group
  optIn:   <labelSelector>   # clusters labelled component.platform/<name>=enabled

byGroup excludes clusters carrying the component label with "enabled" (already
covered by optIn, avoids duplicate Applications) or "disabled" (opt-out).

Usage: include "platform.selection" (dict "name" $name "root" $) | fromYaml
*/}}
{{- define "platform.selection" -}}
{{- $name := .name -}}
{{- $v := .root.Values -}}
{{- $compLabel := printf "%s%s" $v.labels.componentPrefix $name -}}
{{- $groups := list -}}
{{- range $g, $list := $v.groups | default dict -}}
{{- if has $name $list -}}
{{- $groups = append $groups $g -}}
{{- end -}}
{{- end -}}
{{- $common := has $name ($v.common | default list) -}}
{{- if or $common $groups }}
byGroup:
  matchExpressions:
    - key: {{ $v.labels.group | quote }}
      {{- if $common }}
      operator: Exists
      {{- else }}
      operator: In
      values: {{ $groups | sortAlpha | toJson }}
      {{- end }}
    - key: {{ $compLabel | quote }}
      operator: NotIn
      values: ["enabled", "disabled"]
{{- end }}
optIn:
  matchLabels:
    {{ $compLabel | quote }}: "enabled"
{{- end -}}

{{/*
Groups that include a component (for labels/annotations). Usage:
include "platform.groupsOf" (dict "name" $name "root" $)
*/}}
{{- define "platform.groupsOf" -}}
{{- $name := .name -}}
{{- $out := list -}}
{{- if has $name (.root.Values.common | default list) -}}
{{- $out = append $out "common" -}}
{{- end -}}
{{- range $g, $list := .root.Values.groups | default dict -}}
{{- if has $name $list -}}
{{- $out = append $out $g -}}
{{- end -}}
{{- end -}}
{{- $out | sortAlpha | join "," -}}
{{- end -}}

{{/*
Config-repository path with {component}, {group} and {cluster} replaced; the
last two become ApplicationSet go-templates evaluated per cluster.
Usage: include "platform.path" (dict "path" $p "name" $component "root" $)
*/}}
{{- define "platform.path" -}}
{{- $v := .root.Values -}}
{{- .path
    | replace "{component}" .name
    | replace "{group}" (printf "{{ index .metadata.labels %q | default \"_none\" }}" $v.labels.group)
    | replace "{cluster}" "{{ .name }}" -}}
{{- end -}}

{{/* charts revision: the cluster's chartsRevision label, else repos.charts.version */}}
{{- define "platform.chartsRevision" -}}
{{- printf "{{ index .metadata.labels %q | default %q }}" .Values.labels.chartsRevision .Values.repos.charts.version -}}
{{- end -}}

{{/* config revision: the cluster's configRevision label, else repos.config.revision */}}
{{- define "platform.configRevision" -}}
{{- printf "{{ index .metadata.labels %q | default %q }}" .Values.labels.configRevision .Values.repos.config.revision -}}
{{- end -}}
