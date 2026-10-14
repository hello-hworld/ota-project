{{- define "ota-demo.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "ota-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ota-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ota-demo.labels" -}}
{{ include "ota-demo.selectorLabels" . }}
app.kubernetes.io/part-of: ota
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "ota-demo.image" -}}
{{- $digest := required "image.digest가 비어 있다 (sha256:<64 hex>)" .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $digest) -}}
{{- fail (printf "image.digest 형식 오류: %s" $digest) -}}
{{- end -}}
{{- printf "%s@%s" .Values.image.repository $digest -}}
{{- end -}}
