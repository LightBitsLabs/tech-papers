# Lightbits Storage Integration with RHOSO 18

This guide explains how to integrate Lightbits disaggregated NVMe/TCP storage with Red Hat OpenStack Services on OpenShift (RHOSO) 18 as a Cinder block storage backend, including Nova compute (EDPM) configuration for attaching volumes to running VMs.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│           Red Hat OpenShift Cluster                 │
│                                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  Worker 1   │  │  Worker 2   │  │  Worker 3   │  │
│  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │  │
│  │ │ cinder- │ │  │ │ cinder- │ │  │ │ cinder- │ │  │
│  │ │ pods    │ │  │ │ pods    │ │  │ │ pods    │ │  │
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

Cinder pods talk directly to the Lightbits API (create/delete/extend/snapshot volumes, set ACLs) — no local NVMe/TCP attach happens inside the Cinder pods in this configuration, so no CSI or discovery-client involvement is needed on the OCP side.

Separately, EDPM compute nodes run the Lightbits discovery-client (installed directly on the RHEL host, outside OCP) so that `nova-compute` can attach Lightbits volumes to running VMs over NVMe/TCP using the stock os-brick connector.

---

## Prerequisites

- RHOSO 18 deployed on OpenShift 4.18+
- Lightbits cluster accessible from the OpenStack storage network (Cinder pods must reach the Lightbits API; EDPM compute nodes must reach the Lightbits NVMe/TCP targets)
- JWT token for Lightbits API authentication
- All EDPM nodes need the Discovery Client installed - **before** installing the RHOSO cinder driver.
  Follow [Discovery-client Deployment and Usage](https://documentation.lightbitslabs.com/lightbits-private-cloud/discovery-client-deployment-and-usage)

---

## Required Files

| File | Description |
|------|-------------|
| `01-nova-lightbits-configmap.yaml` | Nova privsep config for EDPM compute nodes |
| `02-nova-lightbits-service.yaml` | EDPM DataPlane service for Lightbits setup |
| `03-cinder-config-snippet.yaml` | Cinder section to merge into your OpenStackControlPlane CR |

---

## Step 1: EDPM Compute Node Setup

EDPM compute nodes run `nova-compute` on bare RHEL 9.4 and need special configuration to support Lightbits NVMe/TCP volumes:

```bash
oc apply -f 01-nova-lightbits-configmap.yaml
oc apply -f 02-nova-lightbits-service.yaml
```

Add `nova-lightbits-discovery-client` to your `OpenStackDataPlaneNodeSet` services list, then run the deployment.

---

## Step 2: Deploy the Control Plane

The `03-cinder-config-snippet.yaml` file contains **only the Cinder section** — merge it into your existing `OpenStackControlPlane` CR alongside the other services (keystone, neutron, nova, galera, etc.).

Replace the following placeholders before applying:
- `<LIGHTOS_API_IP>` — Lightbits API server IP address
- `<LIGHTOS_JWT_TOKEN>` — JWT token for Lightbits API authentication

```bash
# Merge the snippet into your OpenStackControlPlane CR, then apply:
oc apply -f your-openstack-control-plane.yaml
oc get openstackcontrolplane -n openstack -w
```

### Cinder Configuration

```yaml
  cinder:
    template:
      cinderVolumes:
        lightbits:
          customServiceConfig: |
            [DEFAULT]
            enabled_backends = lightbits
            default_volume_type = lightbits
            [lightbits]
            volume_driver = cinder.volume.drivers.lightos.LightOSVolumeDriver
            volume_backend_name = lightos
            lightos_api_address = <LIGHTOS_API_IP>
            lightos_api_port = 443
            lightos_jwt = <LIGHTOS_JWT_TOKEN>
            lightos_default_num_replicas = 1
            lightos_default_compression_enabled = False
            lightos_api_service_timeout = 30
          replicas: 1
```

No os-brick or Cinder driver patches are needed for this configuration.

---

## Step 3: Post-Deployment OpenStack Configuration

```bash
# Lightbits primary volume type
oc exec -n openstack openstackclient -- openstack volume type create lightbits \
  --property volume_backend_name=lightos

# Multiattach volume type (Lightbits supports RWX block volumes)
oc exec -n openstack openstackclient -- openstack volume type create multiattach \
  --property volume_backend_name=lightos \
  --property "multiattach=<is> True"
```

---

## Step 4: Verify Services

```bash
oc exec -n openstack openstackclient -- openstack volume service list
```

Expected output:
```
| cinder-scheduler | cinder-scheduler-0                  | nova | enabled | up |
| cinder-volume    | cinder-volume-lightbits-0@lightbits | nova | enabled | up |
```

Test volume creation:
```bash
oc exec -n openstack openstackclient -- openstack volume create \
  --size 1 --type lightbits test-vol
sleep 15
oc exec -n openstack openstackclient -- openstack volume show test-vol -c status
# Expected: status = available
oc exec -n openstack openstackclient -- openstack volume delete test-vol
```

Test attach-to-running-VM:
```bash
oc exec -n openstack openstackclient -- openstack server add volume <server> test-vol
```

---

## Adding a New OCP Worker Node

No Cinder-side configuration is needed on new OCP nodes — Cinder pods talk to the Lightbits API directly and don't attach volumes locally.

If you add a new **EDPM compute node**, make sure the Lightbits discovery-client is installed on it per the Prerequisites section, so Nova can attach Lightbits volumes to VMs on that node.

---

## Supported Operations

With this configuration, Lightbits provides the following capabilities to RHOSO:

| Operation | Component | Notes |
|-----------|-----------|-------|
| Block volumes | Cinder | Create, delete, extend, snapshot, retype |
| Multiattach | Cinder | Single volume attached to multiple VMs simultaneously |
| Attach to running VM | Nova | VM attaches a Lightbits volume via the EDPM discovery-client |

---

## Known Limitations

**Consistency groups** — not implemented in the Lightbits Cinder driver. Volumes and snapshots can be managed individually.

**must-gather loop** — the RHOSO must-gather script enters an infinite loop when Cinder reports `free_capacity_gb = 'infinite'` (which Lightbits uses per Launchpad bug #1871371). Workaround: temporarily set `free_capacity_gb = 999999` and `total_capacity_gb = 999999` in the driver, collect must-gather, then revert.
