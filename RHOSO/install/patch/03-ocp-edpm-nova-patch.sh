#!/bin/bash
# 03-ocp-edpm-nova-patch.sh
#
# Run this script from a client that has oc access to the OCP cluster.
# Run AFTER 02-edpm-cinder-patch.sh has been run on ALL EDPM nodes.
# This updates the OpenStackDataPlaneNodeSet and redeploys nova to
# pick up the patched os-brick file and /etc/node-hostname on each EDPM node.

set -euo pipefail

NAMESPACE="openstack"

echo "=== [3/3] Lightbits EDPM Nova patch for OCP ==="

# Check prerequisites
if ! command -v oc &>/dev/null; then
  echo "ERROR: oc not found in PATH"
  exit 1
fi

# Step 1: Update OpenStackDataPlaneNodeSet with extra bind mounts
echo ""
echo "[1/2] Updating OpenStackDataPlaneNodeSet..."
oc get openstackdataplanenodeset openstack-edpm-ipam -n "$NAMESPACE" -o json | \
  python3 -c "
import json, sys
obj = json.load(sys.stdin)
mounts = obj['spec']['nodeTemplate']['ansible']['ansibleVars'].get('edpm_nova_extra_bind_mounts', [])
# Remove existing patch mounts if present (idempotent)
mounts = [m for m in mounts if m['dest'] not in [
  '/usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py',
  '/etc/node-hostname'
]]
# Add patch mounts
mounts.append({
  'src': '/etc/lightbits-nova-lightos.py',
  'dest': '/usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py',
  'options': 'ro'
})
mounts.append({
  'src': '/etc/node-hostname',
  'dest': '/etc/node-hostname',
  'options': 'ro'
})
obj['spec']['nodeTemplate']['ansible']['ansibleVars']['edpm_nova_extra_bind_mounts'] = mounts
print(json.dumps(obj))
" | oc apply -f -

# Step 2: Redeploy nova
echo ""
echo "[2/2] Redeploying nova on all EDPM nodes..."
DEPLOYMENT_NAME="edpm-deployment-lightbits-nova-patch-$(date +%s)"
oc apply -f - <<EOF
apiVersion: dataplane.openstack.org/v1beta1
kind: OpenStackDataPlaneDeployment
metadata:
  name: $DEPLOYMENT_NAME
  namespace: $NAMESPACE
spec:
  nodeSets:
    - openstack-edpm-ipam
  servicesOverride:
    - nova
EOF

echo ""
echo "Waiting for EDPM deployment to complete (timeout: 10 minutes)..."
oc wait openstackdataplanedeployment "$DEPLOYMENT_NAME" \
  -n "$NAMESPACE" \
  --for=condition=Ready \
  --timeout=600s

echo ""
echo "=== EDPM Nova patch complete ==="
echo ""
echo "Verify patch is applied:"
echo ""
echo "On your OCP client:"
oc exec -n "$NAMESPACE" cinder-volume-lightbits-0 -- \
  grep -q "host_ips" /usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py \
  && echo "  Cinder: patch applied" || echo "  Cinder: patch is NOT applied"
echo ""
echo "On each EDPM node run:"
echo "  podman exec nova_compute grep -q host_ips /usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py && echo 'patch applied' || echo 'patch is NOT applied'"
