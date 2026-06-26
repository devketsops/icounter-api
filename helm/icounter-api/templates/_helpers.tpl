{{- define "app.name" -}}
{{- .Release.Name }}
{{- end }}

{{- define "app.labels" -}}
app: {{ include "app.name" . }}
environment: {{ .Values.environment }}
managed-by: helm
{{- end }}
