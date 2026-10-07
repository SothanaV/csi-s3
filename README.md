# CSI for S3

This is a Container Storage Interface ([CSI](https://github.com/container-storage-interface/spec/blob/master/spec.md)) for S3 (or S3 compatible) storage. This can dynamically allocate buckets and mount them via a fuse mount into any container.

This fork adds:

* `skipSSLVerify` secret option to disable TLS certificate verification (self-signed / private CA endpoints), applied to the S3 API client and to all four mounters
* Multi-segment bucket prefixes (e.g. `team/data/vol-1`) work correctly with `usePrefix: "true"`
* rclone uses path-style addressing (`--s3-provider=Other`) for endpoints without a region, instead of AWS virtual-host addressing which does not resolve for S3 compatible endpoints
* `bucket` + `prefix` without `usePrefix` gives every volume its own folder `<prefix>/<volume-id>` under a common prefix root, instead of one shared bucket
* s3backer block volumes work from a container: loop device nodes are pre-created and a stale `already mounted` token from a crashed driver is reset automatically; a `CSIDriver` object with `fsGroupPolicy: File` is provided so `fsGroup` ownership applies
* Images buildable again: the buster base images now use `archive.debian.org`, dependencies resolve from `go.sum` instead of `go get`

## Status

This is still very experimental and should not be used in any production environment. Unexpected data loss could occur depending on what mounter and S3 storage backend is being used.

## Images

Prebuilt images for this fork are pushed to Docker Hub:

```
sothanav/csi-s3:v1.2.0-rc.2-skipssl6        # full variant: rclone, s3fs, goofys, s3backer
```

To build your own:

```bash
make container VERSION=<tag> REGISTRY_NAME=<registry>
# s3backer variant is built as <tag>-full as well
```

## Kubernetes installation

### Requirements

* Kubernetes 1.13+ (CSI v1.0.0 compatibility)
* Kubernetes has to allow privileged containers
* Docker daemon must allow shared mounts (systemd flag `MountFlags=shared`)

Two ways to install: the Helm chart in `_deploy/` (next section) or the raw
manifests in `deploy/kubernetes/` (sections 1-4 below). They create the same
objects with the same names, so pick one — adopting an existing
manifest-based install into Helm is documented in
[_deploy/README.md](_deploy/README.md#existing-kubectl-installation).

### Install with Helm

Storage classes must be described in a values file: `--set storageClasses[0].x=y`
replaces the whole list entry and drops `name`/`enabled`.

```yaml
# my-values.yaml
storageClasses:
  - name: csi-s3
    enabled: true
    mounter: rclone
    bucket: <S3-BUCKET-NAME>
    prefix: infrastructure/k8s-volumes
```

```bash
# 1. render and check
helm template csi-s3 _deploy -n kube-system -f my-values.yaml

# 2. install (create the credentials secret first, see step 1 below)
helm upgrade --install csi-s3 _deploy -n kube-system -f my-values.yaml
```

Expected output: `Release "csi-s3" has been upgraded. Happy Helming!`

Verify the node plugin and controllers, then test a volume with a PVC as in
step 4 below:

```bash
kubectl -n kube-system get pods -l app=csi-s3
kubectl get csidriver ch.ctrox.csi.s3-driver
kubectl get sc
```

All values (sidecar images, storage classes, kubelet paths, an optional
chart-managed secret) are in [_deploy/values.yaml](_deploy/values.yaml);
the full parameter table and a private-endpoint example
([_deploy/values/example.yaml](_deploy/values/example.yaml)) are in
[_deploy/README.md](_deploy/README.md).

### 1. Create a secret with your S3 credentials

```yaml
apiVersion: v1
kind: Secret
metadata:
  namespace: kube-system
  # Namespace depends on the configuration in the storageclass.yaml
  name: csi-s3-secret
stringData:
  accessKeyID: <YOUR_ACCESS_KEY_ID>
  secretAccessKey: <YOUR_SECRET_ACCES_KEY>
  # For AWS set it to "https://s3.<region>.amazonaws.com", GoogleBucket set to "https://storage.googleapis.com"
  endpoint: <S3_ENDPOINT_URL>
  # If not on S3, set it to ""
  region: <S3_REGION>
```

apply secret
```bash
cd deploy/kebernetes
kubectl create -f secret.yaml
```

The region can be empty if you are using some other S3 compatible storage.

For an HTTPS endpoint with an unverifiable certificate (self-signed or private CA), also add `skipSSLVerify: "true"` to the secret — see [TLS certificate verification](#tls-certificate-verification-skipsslverify).

### 2. Deploy the driver

```bash
cd deploy/kubernetes
kubectl create -f provisioner.yaml
kubectl create -f attacher.yaml
kubectl create -f csi-s3.yaml
```

### 3. Create the storage class

- edit bucket name
```yaml
kind: StorageClass
...
parameters:
  # to use an existing bucket, specify it here:
  bucket: some-existing-bucket
  ...
```

- apply

```bash
kubectl create -f examples/storageclass.yaml
```

### 4. Test the S3 driver

1. Create a pvc using the new storage class:

    ```bash
    kubectl create -f examples/pvc.yaml
    ```

1. Check if the PVC has been bound:

    ```bash
    $ kubectl get pvc csi-s3-pvc
    NAME         STATUS    VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
    csi-s3-pvc   Bound     pvc-c5d4634f-8507-11e8-9f33-0e243832354b   5Gi        RWO            csi-s3         9s
    ```

1. Create a test pod which mounts your volume:

    ```bash
    kubectl create -f examples/pod.yaml
    ```

    If the pod can start, everything should be working.

1. Test the mount

    ```bash
    $ kubectl exec -ti csi-s3-test-nginx bash
    $ mount | grep fuse
    s3fs on /var/lib/www/html type fuse.s3fs (rw,nosuid,nodev,relatime,user_id=0,group_id=0,allow_other)
    $ touch /var/lib/www/html/hello_world
    ```

If something does not work as expected, check the troubleshooting section below.

## Additional configuration

### Bucket

By default, csi-s3 will create a new bucket per volume. The bucket name will match that of the volume ID. If you want your volumes to live in a precreated bucket, you can simply specify the bucket in the storage class parameters:

```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: csi-s3-existing-bucket
provisioner: ch.ctrox.csi.s3-driver
parameters:
  mounter: rclone
  bucket: some-existing-bucket-name
```

If the bucket is specified, it will still be created if it does not exist on the backend. Every volume will get its own prefix within the bucket which matches the volume ID. When deleting a volume, also just the prefix will be deleted.

#### Using an existing bucket with custom prefix

If you have an existing bucket and with or without a prefix (subpath), you can specify to use a prefixed configuration by setting the parameters as:

```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: csi-s3-existing-bucket
provisioner: ch.ctrox.csi.s3-driver
reclaimPolicy: Retain
parameters:
  mounter: rclone
  bucket: some-existing-bucket-name
  # 'usePrefix' must be true in order to enable the prefix feature and to avoid the removal of the prefix or bucket
  usePrefix: "true"
  # 'prefix' can be empty (it will mount on the root of the bucket), an existing prefix or a new one.
  prefix: custom-prefix
```
**Note:** all volumes created with this `StorageClass` will always be mounted to the same bucket and path, meaning they will be identical.

The prefix may contain multiple segments (e.g. `team/data/volumes`). Note that with `usePrefix: "true"` the S3 credentials then also need access to `HEAD`/`LIST` on that exact prefix — backends that scope credentials per prefix (object-lock style ACLs) may reject s3fs, which validates the bucket itself at mount time; rclone works with such credentials.

#### Bucket with per-volume prefixes under a common root

If `bucket` and `prefix` are set **without** `usePrefix`, each volume gets its own folder `<prefix>/<volume-id>` underneath the prefix, instead of at the root of the bucket:

```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: csi-s3
provisioner: ch.ctrox.csi.s3-driver
parameters:
  mounter: rclone
  bucket: some-existing-bucket-name
  # volumes live under <prefix>/<volume-id>/csi-fs, one per volume
  prefix: team/data/volumes
```

Every volume keeps its own metadata and capacity, and deleting a volume only removes its own folder. Without `prefix` the per-volume folders are created at the root of the bucket (default behavior). If the bucket does not exist yet it is created, which requires the credentials to allow it.

### TLS certificate verification (skipSSLVerify)

By default the server certificate of an `https` endpoint is always verified. If your storage uses a self-signed certificate or a private CA and you cannot install the CA certificate, certificate verification can be disabled with `skipSSLVerify` in the secret:

```yaml
stringData:
  accessKeyID: <YOUR_ACCESS_KEY_ID>
  secretAccessKey: <YOUR_SECRET_ACCES_KEY>
  endpoint: https://s3.internal.example
  region: ""
  # accepts true/false (also "1"/"0"), empty means verify (default)
  skipSSLVerify: "true"
```

This applies to the S3 API client (bucket create / metadata read / prefix delete) and to the filesystem mount, using the matching mechanism per mounter:

| Mounter | Mechanism |
| --- | --- |
| rclone | `--no-check-certificate` |
| s3fs | `-o no_check_certificate` |
| s3backer | `--insecure` (only with `--ssl`) |
| goofys | `InsecureSkipVerify` on the shared HTTP transport |

Because the option is on the secret, it reaches the provisioner and every node publish/stage call. Changing the secret takes effect for new volumes and new mounts; pods that already have the volume mounted must be recreated to remount with the new setting.

Mounting with an unverifiable certificate is a trade-off against MITM attacks; installing the CA into the cluster nodes or baking it into a custom image is always the better option.

### Mounter

As S3 is not a real file system there are some limitations to consider here. Depending on what mounter you are using, you will have different levels of POSIX compability. Also depending on what S3 storage backend you are using there are not always [consistency guarantees](https://github.com/gaul/are-we-consistent-yet#observed-consistency).

The driver can be configured to use one of these mounters to mount buckets:

* [rclone](https://rclone.org/commands/rclone_mount)
* [s3fs](https://github.com/s3fs-fuse/s3fs-fuse)
* [goofys](https://github.com/kahing/goofys)
* [s3backer](https://github.com/archiecobbs/s3backer)

The mounter can be set as a parameter in the storage class. You can also create multiple storage classes for each mounter if you like.

All mounters have different strengths and weaknesses depending on your use case. Here are some characteristics which should help you choose a mounter:

#### rclone

* Almost full POSIX compatibility (depends on caching mode)
* Files can be viewed normally with any S3 client

#### s3fs

* Large subset of POSIX
* Files can be viewed normally with any S3 client

#### goofys

* Weak POSIX compatibility
* Performance first
* Files can be viewed normally with any S3 client
* Does not support appends or random writes

#### s3backer (experimental*)

* Represents a block device stored on S3
* Allows to use a real filesystem
* Files are not readable with other S3 clients
* Support appends
* Supports compression before upload (Not yet implemented in this driver)
* Supports encryption before upload (Not yet implemented in this driver)

*s3backer is experimental at this point because volume corruption can occur pretty quickly in case of an unexpected shutdown of a Kubernetes node or CSI pod.
The s3backer binary is not bundled with the normal docker image to keep that as small as possible. Use the `<version>-full` image tag for testing s3backer.

Notes for using the s3backer mounter (see `deploy/kubernetes/examples/storageclass-s3backer.yaml`):

* Deploy `deploy/kubernetes/csi-driver.yaml` (a `CSIDriver` object with `fsGroupPolicy: File`). Without it kubelet never applies the pod's `fsGroup` to volumes of this driver and non-root workloads — postgres being the classic case — fail on the XFS root ownership.
* The driver pre-creates `/dev/loop0..63` device nodes because loop-control may hand out any free loop number while a privileged container only sees the nodes host udev has already created.
* If the driver pod dies while a volume is staged, s3backer's `already mounted` token is left behind in the bucket. The driver now detects this, resets the token and retries the mount.

Fore more detailed limitations consult the documentation of the different projects.

## Troubleshooting

### Issues while creating PVC

Check the logs of the provisioner:

```bash
kubectl logs -l app=csi-provisioner-s3 -c csi-s3
```

### Issues creating containers

1. Ensure feature gate `MountPropagation` is not set to `false`
2. Check the logs of the s3-driver:

```bash
kubectl logs -l app=csi-s3 -c csi-s3
```

### Issues Attacher access denind

log like
```
I1127 12:05:38.226712       1 utils.go:97] GRPC call: /csi.v1.Node/NodeStageVolume
I1127 12:05:38.226726       1 utils.go:98] GRPC request: {"secrets":"***stripped***",...}
E1127 12:05:38.830421       1 utils.go:101] GRPC error: Access Denied.
```

check permission at Object Storage

### TLS certificate errors (x509: certificate signed by unknown authority)

Either install the CA certificate of the storage endpoint on the nodes / inside the driver image, or set `skipSSLVerify: "true"` in the secret (see [TLS certificate verification](#tls-certificate-verification-skipsslverify)). Note that s3fs needs version 1.80 or newer for the corresponding mount option.

### `The specified key does not exist` when staging a volume of a prefixed bucket

The driver stores volume metadata at `<prefix>/.metadata.json` and reads it at each stage/publish. With `usePrefix: "true"` the credentials need `GetObject` on exactly that key, and the volume ID must survive provisioning intact (`<bucket>/<prefix>`). Verify metadata exists with e.g. `rclone cat <remote>:<bucket>/<prefix>/.metadata.json`. In this fork this was also caused by `volumeIDToBucketPrefix` truncating multi-segment prefixes (`infrastructure/k8s-volumes-dev/csi-test` became `infrastructure`), fixed by `SplitN`.

### `bucket not found` with s3fs on a prefix-scoped bucket

s3fs sends a bucket level check at the beginning of the mount. If that call is not granted to the prefix and is answered with an S3 error, the mount aborts. Switch such storage classes to the `rclone` mounter, which only operates within the prefix.

## Development

This project can be built like any other go application.

```bash
go get -u github.com/ctrox/csi-s3
```

### Build executable

```bash
make build
```

### Tests

Currently the driver is tested by the [CSI Sanity Tester](https://github.com/kubernetes-csi/csi-test/tree/master/pkg/sanity). As end-to-end tests require S3 storage and a mounter like s3fs, this is best done in a docker container. A Dockerfile and the test script are in the `test` directory. The easiest way to run the tests is to just use the make command:

```bash
make test
```
