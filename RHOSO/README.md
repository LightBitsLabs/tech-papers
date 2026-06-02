# RHOSO 18 + LightBits Integration

This directory contains the configuration files required to integrate LightBits LightOS storage with Red Hat OpenStack Services on OpenShift (RHOSO) 18.

## Overview

LightBits LightOS provides NVMe/TCP disaggregated storage for OpenStack workloads. This integration enables:
- **Cinder**: LightBits volume backend for persistent block storage
- **Nova**: Compute nodes using LightBits volumes for VM disks via the discovery-client

> **Note:** This repo also contains additional files (`01-controlplane-nncp.yaml`, `02-ctlplane-IPAddressPool.yaml`, `03-openstack-ipAddressPools.yaml`, `04-openstack_netconfig.yaml`) that were used in a reference SNO-based RHOSO + LightBits deployment. These are provided as examples but are not the focus of this guide. The core LightBits integration files are the three listed below.

## Prerequisites

- RHOSO 18 deployed on OpenShift 4.18+
- LightBits LightOS cluster accessible from the OpenStack network
- LightBits discovery-client installed on all EDPM compute nodes
- A StorageClass available on the OCP cluster, this can be a Lightbits StorageClass or other provider, this is used for glance and for the mandatory cinder backup service. In the supplied file the name "lb-replica1-xfs" was used.

## Files

### `01-nova-lightbits-configmap.yaml`
ConfigMap providing the nova-compute privsep configuration for LightBits. This enables the `privsep-helper` to run with the correct privileges needed for NVMe/TCP operations.

**Apply with:**
```bash
oc apply -f 01-nova-lightbits-configmap.yaml
```

### `02-nova-lightbits-service.yaml`
OpenStackDataPlaneService that configures EDPM compute nodes for LightBits. This service:
- Creates the nova sudoers file with SETENV privileges for privsep-helper
- Creates `/run/lightos` directory and makes it persistent via tmpfiles.d
- Patches the nova_compute container JSON to add LightBits volume mounts
- Recreates the nova_compute container with the new configuration

**Apply with:**
```bash
oc apply -f 02-nova-lightbits-service.yaml
```

Then add `nova-lightbits-discovery-client` to your `OpenStackDataPlaneNodeSet` services list and run the deployment:
```bash
oc apply -f <your-nodeset>.yaml
```

### `05-openstack_control_plane_glance_using_pvc.yaml`
Full OpenStackControlPlane manifest with:
- **Cinder** configured with LightBits volume backend (`lightbits`)
- **Glance** using a PVC for image storage
- **Cinder Backup** using a PVC with posix driver
- RabbitMQ cell1 exposed via MetalLB for EDPM compute node access

**Apply with:**
```bash
# Create required PVCs first
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

# Then apply the control plane
oc apply -f 05-openstack_control_plane_glance_using_pvc.yaml
```

## Deployment Order

1. Apply the ConfigMap:
   ```bash
   oc apply -f 01-nova-lightbits-configmap.yaml
   ```

2. Deploy the control plane (creates Cinder with LightBits backend):
   ```bash
   oc apply -f 05-openstack_control_plane_glance_using_pvc.yaml
   ```

3. Wait for the control plane to be ready:
   ```bash
   oc get openstackcontrolplane -n openstack -w
   ```

4. Apply the EDPM service and deploy compute nodes:
   ```bash
   oc apply -f 02-nova-lightbits-service.yaml
   # Add nova-lightbits-discovery-client to your nodeset and deploy
   ```

5. Verify Cinder volume service is up:
   ```bash
   oc exec -n openstack openstackclient -- openstack volume service list
   ```

6. Verify nova-compute is registered:
   ```bash
   oc exec -n openstack openstackclient -- openstack compute service list
   ```

## Cinder LightBits Backend Configuration

The Cinder volume backend section in the control plane uses the following key parameters:

| Parameter | Description |
|-----------|-------------|
| `lightos_api_address` | LightOS API server IP/hostname |
| `lightos_api_port` | LightOS API port (default: 443) |
| `lightos_jwt` | JWT token for LightOS authentication |
| `lightos_default_num_replicas` | Number of data replicas (1-3) |
| `lightos_default_compression_enabled` | Enable/disable compression |
| `lightos_api_service_timeout` | API call timeout in seconds |

## Troubleshooting

### privsep-helper fails
Ensure the ConfigMap is applied and the nova-compute container has the correct config file:
```bash
podman exec nova_compute cat /var/lib/config-data/nova/etc/nova/nova.conf.d/02-nova-lightbits.conf
```

### /run/lightos missing
The `tmpfiles.d` rule in `02-nova-lightbits-service.yaml` creates this on boot. To create it manually:
```bash
mkdir -p /run/lightos
```

### RabbitMQ connection refused from compute node
Verify static routes are in place on the compute node so it can reach the MetalLB internalapi addresses.
