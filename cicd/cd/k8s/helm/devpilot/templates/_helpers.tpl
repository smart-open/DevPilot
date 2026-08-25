{{/*
DevPilot Helm Chart - 模板辅助函数
*/}}

{{/*
Chart 全名（name + version）
*/}}
{{- define "devpilot.fullname" -}}
{{- .Chart.Name -}}-{{- .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Chart 名称
*/}}
{{- define "devpilot.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Chart 标签
*/}}
{{- define "devpilot.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: devpilot
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
命名空间
*/}}
{{- define "devpilot.namespace" -}}
{{- default .Release.Namespace .Values.global.namespace -}}
{{- end -}}

{{/*
Redis 全限定名称
*/}}
{{- define "devpilot.redis.fullname" -}}
{{- printf "%s-redis" (include "devpilot.name" .) -}}
{{- end -}}

{{/*
OpenClaw 全限定名称
*/}}
{{- define "devpilot.openclaw.fullname" -}}
{{- printf "%s-openclaw" (include "devpilot.name" .) -}}
{{- end -}}

{{/*
CC-Switch + Claude Code 全限定名称
*/}}
{{- define "devpilot.ccSwitchClaude.fullname" -}}
{{- printf "%s-devpilot-claude-litellm" (include "devpilot.name" .) -}}
{{- end -}}

{{/*
镜像拉取 Secret 列表
*/}}
{{- define "devpilot.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets -}}
imagePullSecrets:
{{- toYaml . | nindent 0 -}}
{{- end -}}
{{- end -}}

{{/*
Redis 选择器标签
*/}}
{{- define "devpilot.redis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devpilot.redis.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: cache
{{- end -}}

{{/*
OpenClaw 选择器标签
*/}}
{{- define "devpilot.openclaw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devpilot.openclaw.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: bot
{{- end -}}

{{/*
CC-Switch 选择器标签
*/}}
{{- define "devpilot.ccSwitchClaude.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devpilot.ccSwitchClaude.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: coding
{{- end -}}
