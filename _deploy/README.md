# csi-s3 Helm Chart

Helm chart for deploying this CSI S3 driver (node DaemonSet, controller sidecars, RBAC, CSIDriver object, storage classes).

## Table of Contents

- [Layout](#layout)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Value Reference](#value-reference)
- [Credentials Secret](#credentials-secret)
- [Storage Classes](#storage-classes)
- [Existing kubectl Installation](#existing-kubectl-installation)
- [Validation](#validation)
- [File Reference](#file-reference)
- [Troubleshooting](#troubleshooting)

---

## Layout

```
_deploy/
├── Chart.yaml                  # chart metadata, appVersion = default driver image tag
├── values.yaml                 # defaults mirroring deploy/kubernetes/*.yaml
├── values/
│   └── example.yaml            # private endpoint + both storage classes, no secrets
├── templates/
│   ├── _helpers.tpl            # names, kubelet paths, image refs, SC parameters
│   ├── namespace.yaml          # optional Namespace (createNamespace)
│   ├── csidriver.yaml          # CSIDriver (fsGroupPolicy)
│   ├── serviceaccount.yaml     # 3 service accounts
│   ├── rbac.yaml               # ClusterRoles + bindings for driver/provisioner/attacher
│   ├── daemonset.yaml          # node plugin: driver-registrar + csi-s3
│   ├── provisioner.yaml        # csi-provisioner + csi-s3 controller, dummy Service
│   ├── attacher.yaml           # csi-attacher, dummy Service
│   ├── secret.yaml             # optional S3 credentials Secret
│   ├── storageclass.yaml       # one StorageClass per storageClasses[] entry
│   ├── tests/
│   │   └── test-pvc-pod.yaml    # helm test: PVC + write pod
│   └── NOTES.txt
└── scripts/
    └── validate_chart.sh       # helm lint --strict + render + kubectl dry-run
```

All commands below run from the repo root.

---

## Prerequisites

- Kubernetes 1.13+ with CSI v1.0.0 support (validated against k3s v1.36)
- Helm 3.8+ or Helm 4 (`helm version`)
- Privileged containers allowed on the cluster (the node plugin needs `SYS_ADMIN` and `/dev/fuse`)
- Docker/containerd with shared mounts (`MountFlags=shared` on systemd)
- An S3 or S3 compatible endpoint with a bucket for volumes

---

## Installation

### 1. Inspect what would be created

```bash
helm template csi-s3 _deploy -n kube-system
```

### 2. Create the credentials secret (or let the chart do it)

```bash
kubectl -n kube-system create secret generic csi-s3-secret \
  --from-literal=accessKeyID='<ACCESS-KEY-ID>' \
  --from-literal=secretAccessKey='<SECRET-ACCESS-KEY>' \
  --from-literal=endpoint='<S3-ENDPOINT-URL>' \
  --from-literal=region='<S3-REGION>'
```

> **Warning:** with `secret.create=true` the credentials land in the Helm release secret (`sh.helm.release.v1.*`) in the namespace. On a shared cluster, create the Secret out of band and keep `secret.create=false` (the default).

### 3. Install

File volumes only, one bucket per volume:

```bash
helm upgrade --install csi-s3 _deploy -n kube-system
```

Shared bucket plus the s3backer block class, from the bundled example (edit bucket/endpoint first):

```bash
helm upgrade --install csi-s3 _deploy -n kube-system -f _deploy/values/example.yaml
```

> **Warning:** the driver name `ch.ctrox.csi.s3-driver` is cluster-scoped. Installing a second release of this chart in another namespace registers the same driver again and collides on the kubelet plugin path `/var/lib/kubelet/plugins/ch.ctrox.csi.s3-driver` — one release per cluster.

### 4. Verify

```bash
kubectl -n kube-system get pods -l app=csi-s3
kubectl -n kube-system get pod csi-provisioner-s3-0 csi-attacher-s3-0
kubectl get csidriver ch.ctrox.csi.s3-driver
kubectl get sc
```

Expected output: the DaemonSet pod is `2/2 Ready`, both StatefulSet pods are `Running`, the CSIDriver object exists.

### 5. Test a volume

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-s3-test
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: csi-s3
EOF
kubectl get pvc csi-s3-test
```

Expected output: `STATUS Bound` within a few seconds.

With `tests.enabled=true`, the chart carries the same check as a Helm test:

```bash
helm test csi-s3 -n kube-system
```

---

## Value Reference

| Parameter | Description | Default |
| --------- | ----------- | ------- |
| `namespace` | Namespace for every namespaced object | `kube-system` |
| `createNamespace` | Render a Namespace object for `namespace` | `false` |
| `names.driver` | DaemonSet / ServiceAccount / ClusterRole name | `csi-s3` |
| `names.provisioner` | Provisioner StatefulSet name | `csi-provisioner-s3` |
| `names.attacher` | Attacher StatefulSet name | `csi-attacher-s3` |
| `names.csiDriver` | CSI driver name, cluster-scoped, also the kubelet plugin dir | `ch.ctrox.csi.s3-driver` |
| `driver.image.registry` | Registry of the driver image; `docker.io` renders unqualified | `docker.io` |
| `driver.image.repository` | Driver image repository | `sothanav/csi-s3` |
| `driver.image.tag` | Driver image tag; s3backer needs a `-full` tag | `v1.2.0-rc.2-skipssl6` |
| `driver.image.pullPolicy` | Pull policy for driver and controller containers | `Always` |
| `driver.imagePullSecrets` | Pull secrets for all pods in the chart | `[]` |
| `driver.logLevel` | klog verbosity of the node driver (`-v`) | `5` |
| `driver.kubeletDir` | kubelet root on the host | `/var/lib/kubelet` |
| `driver.hostNetwork` | Run the node plugin on the host network | `true` |
| `driver.dnsPolicy` | Empty omits the field (API server defaults to `ClusterFirst`); set `ClusterFirstWithHostNet` to resolve in-cluster names | `""` |
| `driver.csiDriverObject.create` | Render the CSIDriver object | `true` |
| `driver.csiDriverObject.fsGroupPolicy` | `File` is required for s3backer + non-root workloads | `File` |
| `driver.csiDriverObject.attachRequired` | Omitted when `null` (API server default) | `null` |
| `driver.csiDriverObject.extraSpec` | Raw extra `CSIDriver.spec` fields | `{}` |
| `driver.nodeSelector` | Node selection for the DaemonSet | `{}` |
| `driver.tolerations` | Tolerations for the DaemonSet | `[]` |
| `driver.updateStrategy` | DaemonSet update strategy | `{}` |
| `driver.resources` | Requests/limits for the driver container | `{}` |
| `driver.podAnnotations` / `driver.podLabels` | Extra metadata on the DaemonSet pods | `{}` |
| `driver.affinity` | Affinity rules for the DaemonSet | `{}` |
| `driver.priorityClassName` | PriorityClass of the node plugin | `""` |
| `driver.terminationGracePeriodSeconds` | Grace period for in-flight unmounts | `30` |
| `driver.extraEnv` | Extra env on the driver container | `[]` |
| `driver.extraVolumeMounts` / `driver.extraVolumes` | Extra mounts for the driver container | `[]` |
| `driver.livenessProbe` / `driver.readinessProbe` | Probes for the driver container | `{}` |
| `attacher.enabled` | Deploy the csi-attacher StatefulSet | `true` |
| `attacher.image.*` | `registry.k8s.io/sig-storage/csi-attacher:v3.4.0` | see left |
| `attacher.replicas` | Replicas (the socket is a hostPath, keep 1) | `1` |
| `attacher.logLevel` | klog verbosity of the sidecar (`-v`) | `4` |
| `attacher.tolerations` | Default tolerates control-plane nodes | master `Exists` |
| `attacher.nodeSelector` | Node selection for the attacher | `{}` |
| `attacher.affinity` | Affinity rules for the attacher | `{}` |
| `attacher.resources` | Requests/limits for the attacher | `{}` |
| `attacher.podAnnotations` | Extra annotations on the attacher pod | `{}` |
| `attacher.priorityClassName` | PriorityClass of the attacher pod | `""` |
| `provisioner.enabled` | Deploy the csi-provisioner StatefulSet | `true` |
| `provisioner.image.*` | `registry.k8s.io/sig-storage/csi-provisioner:v3.5.0` | see left |
| `provisioner.replicas` | Replicas (the socket is an emptyDir, keep 1) | `1` |
| `provisioner.logLevel` | klog verbosity of both provisioner containers (`-v`) | `4` |
| `provisioner.extraArgs` | Extra args for csi-provisioner | `[]` |
| `provisioner.nodeSelector` / `provisioner.affinity` / `provisioner.resources` | Scheduling and resources for the provisioner pod | `{}` |
| `provisioner.podAnnotations` / `provisioner.priorityClassName` | Metadata and PriorityClass for the provisioner pod | `{}` / `""` |
| `provisioner.tolerations` | Default tolerates control-plane nodes | master `Exists` |
| `registrar.image.*` | `registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0` | see left |
| `registrar.logLevel` | klog verbosity of the node registrar (`-v`) | `4` |
| `rbac.create` | Render ClusterRoles and bindings | `true` |
| `serviceAccounts.<comp>.create` | Render the ServiceAccount (`driver`, `provisioner`, `attacher`) | `true` |
| `serviceAccounts.<comp>.name` | Use a pre-existing ServiceAccount name | `""` |
| `secret.create` | Render the S3 credentials Secret | `false` |
| `secret.name` | Secret name referenced by the storage classes | `csi-s3-secret` |
| `secret.accessKeyID` / `secret.secretAccessKey` | Credentials, stringData (only with `create=true`) | `""` |
| `secret.endpoint` | S3 endpoint URL | `""` |
| `secret.region` | Region, empty for S3 compatible storage | `""` |
| `secret.skipSSLVerify` | `"true"` to skip TLS verification (fork feature) | `""` |
| `secret.extra` | Extra stringData keys | `{}` |
| `storageClasses` | List of StorageClasses to render. A user-supplied list replaces the default list entirely (Helm does not merge list entries), so name every class you want | see below |
| `tests.enabled` | Render the `helm test` PVC + pod | `false` |
| `tests.storageClassName` | Class used by the test PVC | `csi-s3` |
| `tests.size` | Requested size | `5Gi` |

---

## Credentials Secret

Defaults keep credentials out of the release (`secret.create=false`). Point the chart at an existing Secret with `secret.name`; the storage-class secret references are generated from it.

Creating it in the chart is convenient for single-node dev clusters:

```bash
helm upgrade --install csi-s3 _deploy -n kube-system \
  --set secret.create=true \
  --set secret.endpoint='<S3-ENDPOINT-URL>' \
  --set secret.region='' \
  --set secret.skipSSLVerify='true' \
  --set-string secret.accessKeyID='<ACCESS-KEY-ID>' \
  --set-string secret.secretAccessKey='<SECRET-ACCESS-KEY>'
```

> **Warning:** keep keys out of committed values files. `env` is already git-ignored; put real values in an untracked file and pass it with `-f ~/secrets/csi-s3.yaml`.

Secret keys consumed by the driver: `accessKeyID`, `secretAccessKey`, `endpoint`, `region`, `skipSSLVerify`.

---

## Storage Classes

Each `storageClasses[]` entry renders one StorageClass and wires the six `csi.storage.k8s.io/*-secret-*` parameters from `secret.name` and `storageClasses[].secretNamespace`.

| Field | Description | Default |
| ----- | ----------- | ------- |
| `name` | StorageClass name, referenced by PVCs | required |
| `enabled` | Render this class | `true` |
| `mounter` | `rclone`, `s3fs`, `goofys` or `s3backer` | `rclone` |
| `bucket` | Existing bucket for all volumes; empty means one bucket per volume | `""` |
| `prefix` | Key prefix. With `bucket` + no `usePrefix`, each volume gets `<prefix>/<volume-id>` | `""` |
| `usePrefix` | Only meaningful with `bucket`: keep volumes under the prefix instead of per-volume buckets | `null` |
| `reclaimPolicy` | `Delete` or `Retain` | `Delete` |
| `volumeBindingMode` | `Immediate` or `WaitForFirstConsumer` | `Immediate` |
| `allowVolumeExpansion` | Allow `spec.resources.requests.storage` growth | `false` |
| `secretNamespace` | Namespace of the credentials Secret | `kube-system` |
| `annotations` | Extra annotations, e.g. `storageclass.kubernetes.io/is-default-class` | `{}` |
| `extraParameters` | Extra raw `parameters` entries | `{}` |

Both bundled examples: `csi-s3` (rclone, enabled) and `csi-s3-block` (s3backer, disabled). s3backer needs a `-full` driver image and `driver.csiDriverObject.fsGroupPolicy=File`.

Disable all classes and manage them separately (a `--set` on a list index
replaces the whole list, so this is how to turn every class off; to keep some,
describe them in a values file):

```bash
helm upgrade --install csi-s3 _deploy -n kube-system \
  --set 'storageClasses[0].enabled=false'
```

---

## Existing kubectl Installation

A `kubectl create -f deploy/kubernetes/*.yaml` installation has no release metadata, so `helm install` on top of it fails with `already exists`. Either keep using kubectl, or adopt the live objects into Helm before installing (labels are added by Helm at adoption time):

```bash
NS=kube-system
for kind in serviceaccount/csi-s3 serviceaccount/csi-provisioner-sa \
            serviceaccount/csi-attacher-sa \
            service/csi-provisioner-s3 service/csi-attacher-s3 \
            daemonset/csi-s3 statefulset/csi-provisioner-s3 statefulset/csi-attacher-s3; do
  kubectl -n ${NS} annotate "${kind}" \
    meta.helm.sh/release-name=csi-s3 \
    meta.helm.sh/release-namespace=${NS} --overwrite
  kubectl -n ${NS} label "${kind}" app.kubernetes.io/managed-by=Helm --overwrite
done
for kind in clusterrole/csi-s3 clusterrole/external-provisioner-runner \
            clusterrole/external-attacher-runner clusterrolebinding/csi-s3 \
            clusterrolebinding/csi-provisioner-role clusterrolebinding/csi-attacher-role \
            storageclass/csi-s3 storageclass/csi-s3-block \
            csidriver/ch.ctrox.csi.s3-driver; do
  kubectl annotate "${kind}" \
    meta.helm.sh/release-name=csi-s3 \
    meta.helm.sh/release-namespace=${NS} --overwrite
  kubectl label "${kind}" app.kubernetes.io/managed-by=Helm --overwrite
done
```

Then the install adopts the objects instead of failing, but every live object must already match what the chart renders (`helm diff upgrade` shows the delta):

```bash
helm upgrade --install csi-s3 _deploy -n kube-system
```

Adoption notes:

- The node DaemonSet gains Helm `app.kubernetes.io/*` labels on the first upgrade, so the node plugin rolls one pod per node (no other pod spec change at chart defaults). FUSE mounts of running workload pods survive it, but schedule it like any other driver upgrade.
- Annotate the StorageClasses you actually render from the chart. `csi-s3-block` is `enabled: false` by default; annotating a class the chart does not render leaves it owned by a release that will never update it.
- Do not annotate `secret/csi-s3-secret` while `secret.create=false`: the release manifest does not contain it, so the annotation only blocks future chart-managed use of that name.

Rollback once a release exists:

```bash
helm history csi-s3 -n kube-system
helm rollback csi-s3 <REVISION> -n kube-system
```

> **Warning:** `helm uninstall csi-s3 -n kube-system` deletes the StorageClasses and the CSIDriver object. PVCs bound to those classes stay `Bound` to orphan PVs and new PVCs stay `Pending`. Drain workloads using the volumes first; `Delete` reclaim policy removes volume data from the bucket.

---

## Validation

```bash
bash _deploy/scripts/validate_chart.sh                      # defaults
bash _deploy/scripts/validate_chart.sh csi-s3 kube-system _deploy/values/example.yaml
```

The script runs `helm lint --strict`, renders the chart, and pipes it through `kubectl apply --dry-run=client` so every object is checked against the cluster's API schemas. The dry-run is client-side: it mutates nothing.

---

## File Reference

| File | Description |
| ---- | ----------- |
| `_deploy/Chart.yaml` | Chart name, version, `appVersion` = default driver image tag |
| `_deploy/values.yaml` | Default values, documented inline |
| `_deploy/values/example.yaml` | Private-endpoint example with both storage classes |
| `_deploy/templates/_helpers.tpl` | Name, kubelet path, image and storage-class helpers |
| `_deploy/templates/daemonset.yaml` | Node plugin (driver-registrar + privileged driver) |
| `_deploy/templates/provisioner.yaml` | Provisioning controller (csi-provisioner + driver) |
| `_deploy/templates/attacher.yaml` | Attach controller (csi-attacher) |
| `_deploy/templates/rbac.yaml` | ClusterRoles and bindings for the three components |
| `_deploy/templates/csidriver.yaml` | CSIDriver object with `fsGroupPolicy` |
| `_deploy/templates/storageclass.yaml` | Renders `storageClasses[]` |
| `_deploy/templates/secret.yaml` | Optional S3 credentials Secret |
| `_deploy/templates/tests/test-pvc-pod.yaml` | `helm test` hook: PVC + write pod |
| `_deploy/scripts/validate_chart.sh` | Lint + render + dry-run |
| `deploy/kubernetes/` | Raw manifests the chart mirrors |

---

## Troubleshooting

### `rendered manifests contain a resource that already exists`

The cluster still holds the `kubectl create -f` installation. Either delete those objects first (destructive: it orphans PVs) or adopt them with the annotations and labels in [Existing kubectl Installation](#existing-kubectl-installation).

### Node plugin `CreateContainerConfigError` or `Invalid spec: hostPath type changed`

The plugin directory `/var/lib/kubelet/plugins/<csi-driver-name>` exists with a type the manifest does not expect. Keep `names.csiDriver` unchanged across upgrades; the hostPath uses `DirectoryOrCreate`.

### `Pod Security Policy` / `admission webhook "validate.k3s.io" denied` — privileged rejected

The driver needs `privileged: true` and `SYS_ADMIN`. On a restricted cluster, allow privileged workloads for the driver's namespace (Pod Security admission `privileged`, or the PSP/k3s policy in use) instead of removing the securityContext — the FUSE mount cannot work without it.

### PVC stays `Pending`, no PV created

```bash
kubectl -n kube-system logs csi-provisioner-s3-0 -c csi-provisioner --tail=50
kubectl -n kube-system logs csi-provisioner-s3-0 -c csi-s3 --tail=50
```

`secret not found` means `storageClasses[].secretNamespace` and the Secret namespace disagree. `AccessDenied` means the credentials in the Secret are wrong for `secret.endpoint`.

### `connection refused` on the CSI socket (provisioner)

The controller and the node plugin must agree on `driver.kubeletDir` and `names.csiDriver`: the provisioner mounts `<kubeletDir>/plugins/<csiDriver>` as `emptyDir`, the DaemonSet uses the hostPath of the same path. On a kubelet with a non-default root (k3s/k0s with a custom `--kubelet-root-dir`), set `driver.kubeletDir` on both.

### s3backer storage class mounts fail

The image tag must be a `-full` variant (`driver.image.tag`), and the loop device nodes must be creatable on the host — the `-full` image pre-creates them. Non-root workloads need `fsGroupPolicy: File` on the CSIDriver object.

### x509 `certificate signed by unknown authority`

Self-signed or private-CA endpoint: set `secret.skipSSLVerify: "true"` (fork feature, applies to the API client and all mounters).
