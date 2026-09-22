# Lightbits RHOSO 18.0.22 Patches

This directory contains scripts to work around issues introduced in RHOSO 18.0.22 where the Lightbits Cinder driver requires `host_ips` from the os-brick connector, which is not yet provided by the shipped os-brick version.

These patches are temporary and will be removed once the upstream fix is backported to a future RHOSO release.

---

## Scripts

| Script | Where to run | Description |
|--------|-------------|-------------|
| `01-ocp-cinder-patch.sh` | Client with the oc binary and kubeconfig to access the OCP cluster | Patches Cinder pods via ConfigMap and extraMount |
| `02-edpm-cinder-patch.sh` | As user Root on *each* EDPM node | Installs patched os-brick file on the EDPM node |
| `03-ocp-edpm-nova-patch.sh` | Client with the oc binary and kubeconfig to access the OCP cluster | Updates NodeSet and redeploys nova on all EDPM nodes |

---

## Order of Execution

### Step 1 — Run on your OCP client

```bash
./01-ocp-cinder-patch.sh
```

This fetches `lightos.py` from the Cinder pod, applies the patch, creates a ConfigMap, and adds the extraMount to the `OpenStackControlPlane`. It saves the patched file as `lightos-patched.py` in the current directory.

### Step 2 — Copy the patched file and 02-edpm-cinder-patch.sh to each EDPM node and then Run on each EDPM

```bash
scp lightos-patched.py cloud-admin@<EDPM-NODE-IP>:/tmp/
scp 02-edpm-cinder-patch.sh cloud-admin@<EDPM-NODE-IP>:/tmp/
```

Once the python and the bash script are copied, run this on every EDPM node. If you have 10 EDPM nodes, run it 10 times.

```bash
./02-edpm-cinder-patch.sh /tmp/lightos-patched.py
```

If the script is in the same directory as `lightos-patched.py`, you can omit the path:

```bash
./02-edpm-cinder-patch.sh
```

### Step 3 — Run on your OCP client

Run this once after Step 3 is complete on ALL EDPM nodes. It redeploys nova across all nodes in a single operation.

```bash
./03-ocp-edpm-nova-patch.sh
```

---

## Verification

After all steps complete, verify on each EDPM node:
(you also have these commands at the end of the 03-ocp-edpm-nova-patch.sh script)
```bash
podman exec nova_compute grep -n host_ips \
  /usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py

podman exec nova_compute cat /etc/node-hostname
```

And on the OCP client:

```bash
oc exec -n openstack cinder-volume-lightbits-0 -- grep -n host_ips \
  /usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py
```
