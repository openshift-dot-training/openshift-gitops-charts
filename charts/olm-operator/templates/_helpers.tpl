{{- define "olm.namespace" -}}
{{- .Values.namespace.name | default .Release.Namespace -}}
{{- end -}}

{{/* versions.<release name> as YAML (empty dict when absent) */}}
{{- define "olm.version" -}}
{{- index (.Values.versions | default dict) .Release.Name | default dict | toYaml -}}
{{- end -}}

{{/* Effective install plan approval: versions.<name> wins over subscription.* */}}
{{- define "olm.approval" -}}
{{- $v := include "olm.version" . | fromYaml -}}
{{- $v.installPlanApproval | default .Values.subscription.installPlanApproval -}}
{{- end -}}

{{/* Exact CSV name from versions.<name>.csv or .version + subscription.csvFormat.
     Fails the render for Manual approval without a version. */}}
{{- define "olm.csv" -}}
{{- $v := include "olm.version" . | fromYaml -}}
{{- $s := .Values.subscription -}}
{{- if $v.csv -}}
{{- $v.csv -}}
{{- else if $v.version -}}
{{- printf ($s.csvFormat | default (printf "%s.v%%s" $s.name)) (toString $v.version) -}}
{{- else if eq (include "olm.approval" .) "Manual" -}}
{{- fail (printf "versions.%s.version is required: installPlanApproval is Manual, so the exact operator version must be set (components/versions.yaml, group-values/<group>/versions.yaml or the cluster environment repo)" .Release.Name) -}}
{{- end -}}
{{- end -}}

{{- define "olm.approverName" -}}
{{- printf "%s-installplan-approver" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
