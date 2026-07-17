# Lightbits Storage Integration with RHOSO 18

This guide explains how to integrate Lightbits disaggregated NVMe/TCP storage with Red Hat OpenStack Services on OpenShift (RHOSO) 18, covering the Cinder block storage backend, Glance image storage, Cinder backup, and Nova compute (EDPM) configuration.

---

> **For in-depth technical background** on how these patches work, why they are needed, and the full OpenStackControlPlane CR used in the reference deployment, see the [`../whitepaper/`](../whitepaper/) directory.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│           Red Hat OpenShift Cluster                 │
│                                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  Worker 1   │  │  Worker 2   │  │  Worker 3   │  │
│  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │  │
│  │ │OpenStack│ │  │ │OpenStack│ │  │ │OpenStack│ │  │
│  │ │  pods   │ │  │ │  pods   │ │  │ │  pods   │ │  │
│  │ ├─────────┤ │  │ ├─────────┤ │  │ ├─────────┤ │  │
│  │ │lb-csi   │ │  │ │lb-csi   │ │  │ │lb-csi   │ │  │
│  │ │  node   │ │  │ │  node   │ │  │ │  node   │ │  │
│  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │         EDPM Compute Nodes (RHEL 9.4)        │   │
│  │  nova-compute + KVM + Lightbits discovery    │   │
│  └──────────────────────────────────────────────┘   │
└──────────────────────────────┬──────────────────────┘
                               │ NVMe/TCP
                    ┌──────────▼──────────┐
                    │  Lightbits Cluster  │
                    │  (NVMe/TCP targets) │
                    └─────────────────────┘
```

The Lightbits CSI DaemonSet (`lb-csi-node`) runs on every OCP worker node and provides two functions:
- **CSI driver** — provisions PVCs for OpenStack infrastructure pods (Galera, RabbitMQ, etc.)
- **Discovery Client (dc)** — handles NVMe/TCP connections for Cinder local attach operations (backup, create-from-image, boot-from-volume)

---

## Prerequisites

- RHOSO 18 deployed on OpenShift 4.18+
- Lightbits cluster accessible from the OpenStack storage network
- Lightbits Operator installed on the OCP cluster (provides the `lb-csi-node` DaemonSet)
- Lightbits CSI StorageClass created (referenced as `lb-replica1-xfs` in this guide)
- JWT token for Lightbits API authentication
- All EDPM nodes need the Discovery Client installed - **before** installing the RHOSO cinder driver. 
  Follow [Discovery-client Deployment and Usage](https://documentation.lightbitslabs.com/lightbits-private-cloud/discovery-client-deployment-and-usage)

---

## Required Files

| File | Description |
|------|-------------|
| `01-nova-Lightbits-configmap.yaml` | Nova privsep config for EDPM compute nodes |
| `02-nova-Lightbits-service.yaml` | EDPM DataPlane service for Lightbits setup |
| `03-lightos-osbrick-patch-configmap.yaml` | Patched os-brick + Cinder driver files |
| `04-lightos-cinder-discovery-pvc.yaml` | PVC for the NVMe/TCP discovery-client directory |
| `05-cinder-glance-config-snippet.yaml` | Cinder + Glance sections to merge into your OpenStackControlPlane CR |

---

## Step 1: EDPM Compute Node Setup

EDPM compute nodes run `nova-compute` on bare RHEL 9.4 and need special configuration to support Lightbits NVMe/TCP volumes:

```bash
oc apply -f 01-nova-Lightbits-configmap.yaml
oc apply -f 02-nova-Lightbits-service.yaml
```

Add `nova-Lightbits-discovery-client` to your `OpenStackDataPlaneNodeSet` services list, then run the deployment. 

---

## Step 2: Create Required PVCs

```bash
# PVC for Glance image storage (file backend, backed by Lightbits via CSI)
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: glance-images-pvc
  namespace: openstack
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: lb-replica1-xfs
---
# PVC for Cinder backup NFS mount point
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cinder-backup-pvc
  namespace: openstack
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: lb-replica1-xfs
EOF

# PVC for the NVMe/TCP discovery-client configuration directory
oc apply -f 04-lightos-cinder-discovery-pvc.yaml
```

---

## Step 3: Apply os-brick and Driver Patches

Three patches are required:

```bash
oc apply -f 03-lightos-osbrick-patch-configmap.yaml
```

---

## Step 4: Deploy the Control Plane

The `05-cinder-glance-config-snippet.yaml` file contains **only the Cinder and Glance sections** — merge them into your existing `OpenStackControlPlane` CR alongside the other services (keystone, neutron, nova, galera, etc.).

Replace the following placeholders before applying:
- `<LIGHTOS_API_IP>` — Lightbits API server IP address
- `<LIGHTOS_JWT_TOKEN>` — JWT token for Lightbits API authentication
- `<NFS_SERVER_IP>` — NFS server IP for Cinder backup
- `<GLANCE_PASSWORD>` — Glance service password (from `osp-secret`)

```bash
# Merge the snippet into your OpenStackControlPlane CR, then apply:
oc apply -f your-openstack-control-plane.yaml
oc get openstackcontrolplane -n openstack -w
```

### Lightbits-Specific Sections in the Control Plane YAML

#### Global StorageClass

```yaml
spec:
  storageClass: lb-replica1-xfs   # Lightbits CSI StorageClass used for all infrastructure PVCs
                                   # (Galera databases, RabbitMQ, etc.)
```

#### Cinder Configuration

The entire Cinder section is Lightbits-specific. Key parts:

```yaml
  cinder:
    template:
      extraMounts:
        # v1: NFS mount point for cinder-backup pod
        - name: v1
          region: r1
          extraVol:
            - propagation: [CinderBackup]
              mounts:
                - name: backup-store
                  mountPath: /var/lib/cinder/backup
              volumes:
                - name: backup-store
                  persistentVolumeClaim:
                    claimName: cinder-backup-pvc

        # v2: Patched os-brick and Cinder driver files (see Step 3)
        - name: v2
          region: r1
          extraVol:
            - propagation: [CinderBackup, CinderVolume]
              mounts:
                - name: lightos-connector-patch
                  mountPath: /usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py
                  subPath: lightos.py
                - name: lightos-connector-patch
                  mountPath: /usr/lib/python3.9/site-packages/os_brick/privileged/lightos.py
                  subPath: lightos_priv.py
              volumes:
                - name: lightos-connector-patch
                  configMap:
                    name: lightos-connector-patch
            - propagation: [CinderVolume]
              mounts:
                - name: lightos-driver-patch
                  mountPath: /usr/lib/python3.9/site-packages/cinder/volume/drivers/lightos.py
                  subPath: lightos_driver.py
              volumes:
                - name: lightos-driver-patch
                  configMap:
                    name: lightos-connector-patch

        # v3: Discovery-client directory (NVMe/TCP .conf files written here)
        - name: v3
          region: r1
          extraVol:
            - propagation: [CinderBackup, CinderVolume]
              mounts:
                - name: discovery-client-dir
                  mountPath: /etc/discovery-client/discovery.d
              volumes:
                - name: discovery-client-dir
                  persistentVolumeClaim:
                    claimName: cinder-discovery-client-pvc

        # v4: Node hostname injected for NQN construction
        # Each Cinder pod reads /etc/node-hostname to build:
        # nqn.2019-09.com.Lightbitslabs:host:<node-name>.node
        # Works automatically on multi-worker clusters.
        - name: v4
          region: r1
          extraVol:
            - propagation: [CinderBackup, CinderVolume]
              mounts:
                - name: node-hostname
                  mountPath: /etc/node-hostname
              volumes:
                - name: node-hostname
                  hostPath:
                    path: /etc/hostname
                    type: File

      cinderVolumes:
        Lightbits:
          customServiceConfig: |
            [DEFAULT]
            enabled_backends = Lightbits
            default_volume_type = lb-replica1-xfs    # Ensures volumes without explicit type go to Lightbits
            [Lightbits]
            volume_driver = cinder.volume.drivers.lightos.LightbitsVolumeDriver
            volume_backend_name = lightos
            lightos_api_address = <LIGHTOS_API_IP>
            lightos_api_port = 443
            lightos_jwt = <LIGHTOS_JWT_TOKEN>
            lightos_default_num_replicas = 1
            lightos_default_compression_enabled = False
            lightos_api_service_timeout = 30
          replicas: 1

      cinderBackup:
        replicas: 1
        customServiceConfig: |
          [DEFAULT]
          backup_driver = cinder.backup.drivers.nfs.NFSBackupDriver
          backup_share = <NFS_SERVER_IP>:/path/to/export
          backup_mount_point_base = /var/lib/cinder/backup
```

#### Glance Configuration

Glance uses a PVC-backed file store (backed by Lightbits via CSI). The `glance-images-pvc` stores VM images on a Lightbits volume:

```yaml
  glance:
    template:
      storage:
        storageClass: lb-replica1-xfs   # Lightbits CSI StorageClass
        storageRequest: 10Gi
      keystoneEndpoint: single
      extraMounts:
        - name: v1
          region: r1
          extraVol:
            - propagation: [GlanceAPI]
              mounts:
                - name: glance-images
                  mountPath: /var/lib/glance/images
              volumes:
                - name: glance-images
                  persistentVolumeClaim:
                    claimName: glance-images-pvc    # Lightbits-backed PVC
      glanceAPIs:
        single:
          customServiceConfig: |
            [DEFAULT]
            enabled_backends = file:file
            [glance_store]
            default_backend = file
            [file]
            filesystem_store_datadir = /var/lib/glance/images
```

#### Galera Database StorageClass

```yaml
  galera:
    templates:
      openstack:
        storageClass: lb-replica1-xfs   # Lightbits CSI StorageClass for database volumes
      openstack-cell1:
        storageClass: lb-replica1-xfs
```

---

## Step 5: Post-Deployment OpenStack Configuration

```bash
# Lightbits primary volume type
oc exec -n openstack openstackclient -- openstack volume type create lb-replica1-xfs \
  --property volume_backend_name=lightos

# Multiattach volume type (Lightbits supports RWX block volumes)
oc exec -n openstack openstackclient -- openstack volume type create multiattach \
  --property volume_backend_name=lightos \
  --property "multiattach=<is> True"
```

**Note on volume type naming:** `lb-replica1-xfs` is used as both the Kubernetes StorageClass name (for CSI PVC provisioning) and the OpenStack Cinder volume type name. These are completely different objects at different layers — the naming overlap is intentional for consistency but they operate independently.

---

## Step 6: Verify Services

```bash
oc exec -n openstack openstackclient -- openstack volume service list
```

Expected output:
```
| cinder-scheduler | cinder-scheduler-0                  | nova | enabled | up |
| cinder-volume    | cinder-volume-Lightbits-0@Lightbits | nova | enabled | up |
| cinder-backup    | cinder-backup-0                     | nova | enabled | up |
```

Test volume creation:
```bash
oc exec -n openstack openstackclient -- openstack volume create \
  --size 1 --type lb-replica1-xfs test-vol
sleep 15
oc exec -n openstack openstackclient -- openstack volume show test-vol -c status
# Expected: status = available
oc exec -n openstack openstackclient -- openstack volume delete test-vol
```

---

## Adding a New OCP Worker Node

The Lightbits CSI DaemonSet (`lb-csi-node`) deploys automatically to all new nodes via the Lightbits Operator. The `hostPath: /etc/hostname` mount (`extraMounts v4`) automatically provides the correct node name to Cinder pods running on that node — no manual configuration is needed.

Verify after adding a new node:
```bash
oc get pods -n openshift-operators -o wide | grep lb-csi-node
```

---

## Supported Operations

With this setup, Lightbits provides the following capabilities to RHOSO:

| Operation | Component | Notes |
|-----------|-----------|-------|
| Block volumes | Cinder | Create, delete, extend, snapshot, retype |
| Multiattach | Cinder | Single volume attached to multiple VMs simultaneously |
| Volume backup | Cinder backup | NVMe/TCP local attach → NFS backup store |
| Create from image | Cinder | NVMe/TCP local attach from Cinder pod |
| Boot from volume | Nova | VM boots directly from Lightbits volume |
| Image storage | Glance | Images stored on Lightbits-backed PVC |
| Infrastructure PVCs | CSI | Galera, RabbitMQ, Glance images |

---

## Known Limitations

**Consistency groups** — not implemented in the Lightbits Cinder driver. Volumes and snapshots can be managed individually.

**Glance Cinder native backend** — storing Glance images directly as Cinder volumes (instead of via a PVC) is possible but has a known `ImageProxy TypeError` bug in RHOSO 18 when downloading images through the `split` layout external API pod. Nova compute EDPM nodes also cannot resolve the `glance-cinder-internal.openstack.svc` endpoint. Use the PVC-backed file store as described in this guide.

**must-gather loop** — the RHOSO must-gather script enters an infinite loop when Cinder reports `free_capacity_gb = 'infinite'` (which Lightbits uses per Launchpad bug #1871371). Workaround: temporarily set `free_capacity_gb = 999999` and `total_capacity_gb = 999999` in `lightos_driver.py`, collect must-gather, then revert.