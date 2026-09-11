# Lightbits Storage Integration with RHOSO 18

This guide covers the steps required to integrate Lightbits disaggregated NVMe/TCP storage with Red Hat OpenStack Services on OpenShift (RHOSO) 18.

---

## Naming Conventions

This guide uses two distinct storage naming layers that are independent of each other:

| Name | Layer | Purpose |
|------|-------|---------|
| `lightbits-volume-replica-2` | OpenStack Cinder volume type | Used by OpenStack users to request Lightbits-backed block volumes. The name reflects the sample configuration in this guide which uses 2 replicas (`lightos_default_num_replicas = 2`). You may choose any name that suits your environment. |
| `lightbits` | Cinder backend key | The `cinderVolumes` key in the `OpenStackControlPlane` CR, which also determines the Cinder service hostname (`cinder-volume-lightbits-0@lightbits`) |
| `lightos` | `volume_backend_name` | The backend name used internally by the Cinder scheduler to match volumes to the correct backend. Referenced in volume type properties. |

---

## Prerequisites

- RHOSO 18 deployed on OpenShift 4.18+
- Lightbits cluster accessible from the OpenStack storage network
- Lightbits Operator installed on the OCP cluster
- JWT token for Lightbits API authentication

---

## Required Files

| File | Description |
|------|-------------|
| `install-01-nova-lightbits-configmap.yaml` | Nova privsep config for EDPM compute nodes |
| `install-02-nova-lightbits-service.yaml` | EDPM DataPlane service |
| `install-03-lightbits-secret.yaml` | Secret storing the Lightbits JWT token |
| `install-04-hostnqn-daemonset.yaml` | DaemonSet to set correct NQN on OCP worker nodes |
| `install-05-sample-config-of-cinder-and-glance.yaml` | Sample Cinder and Glance configuration for your OpenStackControlPlane CR |

---

## Step 1: EDPM Compute Node Setup

```bash
oc apply -f install-01-nova-lightbits-configmap.yaml
oc apply -f install-02-nova-lightbits-service.yaml
```

Add `nova-lightbits-discovery-client` to your `OpenStackDataPlaneNodeSet` services list before `nova`:

```yaml
services:
  - nova-lightbits-discovery-client
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
```

---

## Step 2: Deploy the hostnqn DaemonSet

```bash
oc create serviceaccount lightbits-hostnqn -n openshift-operators
oc adm policy add-scc-to-user privileged -z lightbits-hostnqn -n openshift-operators
oc apply -f install-04-hostnqn-daemonset.yaml
```

Verify:
```bash
oc get pods -n openshift-operators | grep hostnqn
cat /etc/nvme/hostnqn
# Expected: nqn.2019-09.com.lightbitslabs:host:<node-name>.node
```

---

## Step 3: Create the Lightbits JWT Secret

Edit `install-03-lightbits-secret.yaml` and replace `<LIGHTOS_JWT_TOKEN>` with your actual JWT token, then apply:

```bash
oc apply -f install-03-lightbits-secret.yaml
```

---

## Step 4: Deploy the Control Plane

Merge the Lightbits-specific Cinder and Glance configuration from `install-05-sample-config-of-cinder-and-glance.yaml` into your existing `OpenStackControlPlane` CR, replacing the following placeholders:

- `<LIGHTOS_API_IP>` — Lightbits API server IP address
- `<GLANCE_PASSWORD>` — Glance service user password (from osp-secret)

```bash
oc apply -f your-openstack-control-plane.yaml
oc get openstackcontrolplane -n openstack -w
```

---

## Step 5: Post-Deployment OpenStack Configuration

Create the Cinder volume types. The name `lightbits-volume-replica-2` reflects the 2-replica configuration used in this guide (`lightos_default_num_replicas = 2` in `install-05`). Adjust the name and replica count to match your environment.

```bash
# Lightbits primary volume type (2 replicas as configured in install-05)
oc exec -n openstack openstackclient -- openstack volume type create lightbits-volume-replica-2 \
  --property volume_backend_name=lightos

# Multiattach volume type
oc exec -n openstack openstackclient -- openstack volume type create multiattach \
  --property volume_backend_name=lightos \
  --property "multiattach=<is> True"
```

---

## Step 6: Verify

```bash
oc exec -n openstack openstackclient -- openstack volume service list
```

Expected:
```
| cinder-scheduler | cinder-scheduler-0                  | nova | enabled | up |
| cinder-volume    | cinder-volume-lightbits-0@lightbits | nova | enabled | up |
| cinder-backup    | cinder-backup-0                     | nova | enabled | up |
```

---

## Supported Operations

| Operation | Component |
|-----------|-----------|
| Block volumes | Cinder |
| Multiattach volumes | Cinder |
| Volume backup | Cinder backup |
| Create from image | Cinder |
| Boot from volume | Nova |
| Infrastructure PVCs | CSI |
