{{/*
Chart name, overridable; used in labels only — every object name comes from
the explicit names.* values, because CSI names are load-bearing.
*/}}
{{- define "csi-s3.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Namespace to render into.
*/}}
{{- define "csi-s3.namespace" -}}
{{- default "kube-system" .Values.namespace -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "csi-s3.labels" -}}
app.kubernetes.io/name: {{ include "csi-s3.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
CSI driver name (ch.ctrox.csi.s3-driver by default).
*/}}
{{- define "csi-s3.driverName" -}}
{{- required "names.csiDriver is required" .Values.names.csiDriver -}}
{{- end -}}

{{/*
kubelet root directory on the host.
*/}}
{{- define "csi-s3.kubeletDir" -}}
{{- trimSuffix "/" (default "/var/lib/kubelet" .Values.driver.kubeletDir) -}}
{{- end -}}

{{/*
Host path of the driver plugin directory (kubelet plugin registry socket dir).
*/}}
{{- define "csi-s3.pluginDir" -}}
{{- printf "%s/plugins/%s" (include "csi-s3.kubeletDir" .) (include "csi-s3.driverName" .) -}}
{{- end -}}

{{/*
In-container path of the CSI endpoint socket.
*/}}
{{- define "csi-s3.endpoint" -}}
unix:///csi/csi.sock
{{- end -}}

{{/*
Image helper: pass the image block (registry/repository/tag/pullPolicy).
Usage: {{ include "csi-s3.image" .Values.driver.image }}
*/}}
{{- define "csi-s3.image" -}}
{{- $tag := required "image tag is required" .tag -}}
{{- $registry := default "docker.io" .registry -}}
{{- if or (eq $registry "docker.io") (eq $registry "index.docker.io") (empty $registry) -}}
{{- printf "%s:%s" .repository $tag -}}
{{- else -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $registry) .repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Service account name for a component.
Usage: {{ include "csi-s3.serviceAccountName" (dict "root" . "component" "driver") }}
*/}}
{{- define "csi-s3.serviceAccountName" -}}
{{- $root := .root -}}
{{- $cfg := index $root.Values.serviceAccounts .component -}}
{{- if $cfg.name -}}
{{- $cfg.name -}}
{{- else if eq .component "driver" -}}
{{- $root.Values.names.driver -}}
{{- else if eq .component "provisioner" -}}
csi-provisioner-sa
{{- else -}}
csi-attacher-sa
{{- end -}}
{{- end -}}

{{/*
S3 credentials secret name.
*/}}
{{- define "csi-s3.secretName" -}}
{{- required "secret.name is required" .Values.secret.name -}}
{{- end -}}

{{/*
DNS policy for the node plugin. Empty means the field is omitted, matching
deploy/kubernetes/csi-s3.yaml (API server defaults it to ClusterFirst).
Set "ClusterFirstWithHostNet" when the driver must resolve in-cluster service
names from the host network.
*/}}
{{- define "csi-s3.dnsPolicy" -}}
{{- .Values.driver.dnsPolicy | default "" -}}
{{- end -}}

{{/*
Render a storage class parameter map for one storageClasses[] entry.
Expects dict "root" and "sc".
*/}}
{{- define "csi-s3.storageClassParameters" -}}
{{- $root := .root -}}
{{- $sc := .sc -}}
mounter: {{ default "rclone" $sc.mounter | quote }}
{{- if $sc.bucket }}
bucket: {{ $sc.bucket | quote }}
{{- end }}
{{- if $sc.prefix }}
prefix: {{ $sc.prefix | quote }}
{{- end }}
{{- if not (empty $sc.usePrefix) }}
usePrefix: {{ $sc.usePrefix | quote }}
{{- end }}
{{- range $key, $value := $sc.extraParameters }}
{{ $key }}: {{ $value | quote }}
{{- end }}
csi.storage.k8s.io/provisioner-secret-name: {{ include "csi-s3.secretName" $root }}
csi.storage.k8s.io/provisioner-secret-namespace: {{ default (include "csi-s3.namespace" $root) $sc.secretNamespace }}
csi.storage.k8s.io/controller-publish-secret-name: {{ include "csi-s3.secretName" $root }}
csi.storage.k8s.io/controller-publish-secret-namespace: {{ default (include "csi-s3.namespace" $root) $sc.secretNamespace }}
csi.storage.k8s.io/node-stage-secret-name: {{ include "csi-s3.secretName" $root }}
csi.storage.k8s.io/node-stage-secret-namespace: {{ default (include "csi-s3.namespace" $root) $sc.secretNamespace }}
csi.storage.k8s.io/node-publish-secret-name: {{ include "csi-s3.secretName" $root }}
csi.storage.k8s.io/node-publish-secret-namespace: {{ default (include "csi-s3.namespace" $root) $sc.secretNamespace }}
{{- end -}}
