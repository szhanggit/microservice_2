{{/*
Resource names in this chart are intentionally fixed ("frontend") rather than
{{ .Release.Name }}-prefixed - there's only ever one release per cluster
(each environment is its own cluster), so nothing needs to vary by release
name. Matches the same deliberate deviation from Helm's usual naming
convention as the microservice0 reference chart.
*/}}

{{/*
Common labels. Usage: {{- include "frontend.labels" . | nindent 4 }}
*/}}
{{- define "frontend.labels" -}}
app.kubernetes.io/name: frontend
app.kubernetes.io/part-of: microservice2
app.kubernetes.io/component: frontend
{{- end -}}
