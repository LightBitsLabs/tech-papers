# Lightbits Storage Integration with RHOSO 18

This guide explains how to integrate Lightbits disaggregated NVMe/TCP storage with Red Hat OpenStack Services on OpenShift (RHOSO) 18, covering the Cinder block storage backend, Cinder backup, and Nova compute (EDPM) configuration.

> **For in-depth technical background** on the architecture, see the [`../blog-whitepaper/`](../blog-whitepaper/) directory.

---

## Prerequisites

- RHOSO 18.0.22 deployed on OpenShift 4.18+
- Lightbits cluster accessible from the OCP and EDPM storage network
- Lightbits CSI Operator installed on the OCP cluster (provides the `lb-csi-node` DaemonSet)
- Lightbits CSI StorageClass created (referenced here as `lb-replica1-xfs` in this guide)
- JWT token for Lightbits API authentication
- All EDPM nodes need the Discovery Client installed - **before** installing the RHOSO cinder driver.
  Follow [Discovery-client Deployment and Usage](https://documentation.lightbitslabs.com/lightbits-private-cloud/discovery-client-deployment-and-usage)


---

## Required Files

| File | Description |
|------|-------------|
| `install-01-nova-lightbits-configmap.yaml` | Nova privsep config for EDPM compute nodes |
| `install-02-nova-lightbits-service.yaml` | EDPM DataPlane service |
| `install-03-lightos-cinder-discovery-pvc.yaml` | PVCs for Cinder backup and discovery-client |
| `install-04-hostnqn-daemonset.yaml` | DaemonSet to set correct NQN on OCP worker nodes |
| `install-05-sample-config-of-cinder-and-glance.yaml` | Sample Cinder configuration for your OpenStackControlPlane CR |
---

## Step 1: EDPM Compute Node Setup

Apply the Lightbits Nova configuration:

```bash
oc apply -f 01-nova-Lightbits-configmap.yaml
oc apply -f 02-nova-Lightbits-service.yaml
```

Make sure to add the `nova-Lightbits-discovery-client` service to your `OpenStackDataPlaneNodeSet` services list **before** the `nova` service.
```yaml
services:
  - nova-lightbits-discovery-client
  .
  .
  .
  - nova
```
Also add `edpm_nova_extra_bind_mounts` to your `OpenStackDataPlaneNodeSet` `ansibleVars`:

```yaml
spec:
  nodeTemplate:
    ansible:
      ansibleVars:
        edpm_nova_extra_bind_mounts:
          - src: /etc/discovery-client
            dest: /etc/discovery-client
            options: rw,z
          - src: /etc/sudoers.d/nova-Lightbits
            dest: /etc/sudoers.d/nova
            options: ro
```

When the file is ready, run the deployment. This creates on each EDPM node:
- Sudoers entry for `nova-compute` privsep-helper with `SETENV` privileges
- `/etc/discovery-client/discovery.d/` directory

---

## Step 2: Deploy the hostnqn DaemonSet

**Note:** The Lightbits CSI Operator must be properly installed before deploying this DaemonSet.

```bash
# Create ServiceAccount with privileged SCC
oc create serviceaccount Lightbits-hostnqn -n openshift-operators
oc adm policy add-scc-to-user privileged -z Lightbits-hostnqn -n openshift-operators

# Deploy the DaemonSet
oc apply -f install-04-hostnqn-daemonset.yaml
```

Verify:
```bash
oc get pods -n openshift-operators | grep hostnqn
# On each OCP worker node:
cat /etc/nvme/hostnqn
# Expected: nqn.2019-09.com.Lightbitslabs:host:<node-name>.node
```

---

## Step 3: Create Required PVCs

```bash
oc apply -f install-03-lightos-cinder-discovery-pvc.yaml
```

---

## Step 4: Deploy the Control Plane

The `install-05-sample-config-of-cinder-and-glance.yaml` contains **only the Cinder sections** — merge them into your existing `OpenStackControlPlane` CR.

Replace the following placeholders:
- `<LIGHTOS_API_IP>` — Lightbits API server IP address
- `<LIGHTOS_JWT_TOKEN>` — JWT token for Lightbits API authentication
- `<NFS_SERVER_IP>` — NFS server IP for Cinder backup

```bash
oc apply -f your-openstack-control-plane.yaml
oc get openstackcontrolplane -n openstack -w
```

---

## Step 5: Post-Deployment OpenStack Configuration

```bash
# Lightbits primary volume type
oc exec -n openstack openstackclient -- openstack volume type create lightbits-volume-replica-2 \
  --property volume_backend_name=lightos

# Multiattach volume type
oc exec -n openstack openstackclient -- openstack volume type create multiattach \
  --property volume_backend_name=lightos \
  --property "multiattach=<is> True"
```

---

## Step 6: Verify Services

```bash
oc exec -n openstack openstackclient -- openstack volume service list
```

Expected:
```
| cinder-scheduler | cinder-scheduler-0                  | nova | enabled | up |
| cinder-volume    | cinder-volume-Lightbits-0@Lightbits | nova | enabled | up |
| cinder-backup    | cinder-backup-0                     | nova | enabled | up |
```

Test volume creation and backup:
```bash
oc exec -n openstack openstackclient -- openstack volume create \
  --size 1 --type lightbits-volume-replica-2 test-vol
sleep 15
oc exec -n openstack openstackclient -- openstack volume show test-vol -c status
# Expected: status = available

oc exec -n openstack openstackclient -- openstack volume backup create \
  --name test-backup test-vol
sleep 30
oc exec -n openstack openstackclient -- openstack volume backup show test-backup -c status
# Expected: status = available

oc exec -n openstack openstackclient -- openstack volume backup delete test-backup --force
oc exec -n openstack openstackclient -- openstack volume delete test-vol
```

---

## Adding a New OCP Worker Node

The `lb-csi-node` and `Lightbits-hostnqn-init` DaemonSets deploy automatically to new nodes. No manual configuration needed.

---

## Supported Operations

| Operation | Component | Notes |
|-----------|-----------|-------|
| Block volumes | Cinder | Create, delete, extend, snapshot, retype |
| Multiattach | Cinder | Single volume attached to multiple VMs simultaneously |
| Volume backup | Cinder backup | NVMe/TCP local attach → NFS backup store |
| Create from image | Cinder | NVMe/TCP local attach from Cinder pod |
| Boot from volume | Nova | VM boots directly from Lightbits volume |
| Infrastructure PVCs | CSI | Galera, RabbitMQ, Glance images |

---

## Known Limitations

**Consistency groups** — not implemented in the Lightbits Cinder driver.