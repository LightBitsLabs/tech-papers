#!/bin/bash
# 01-ocp-cinder-patch.sh
#
# Run this script from a client that has oc access to the OCP cluster.
# This script patches the Lightbits os-brick connector in the Cinder pods
# to add host_ips support required by the Lightbits Cinder driver in RHOSO 18.0.22+.
#
# After running this script, copy the generated lightos-patched.py file
# to each EDPM node and run 02-edpm-cinder-patch.sh on each one,
# then run 03-ocp-edpm-nova-patch.sh from this client.

set -euo pipefail

NAMESPACE="openstack"
CP_NAME="openstack-control-plane"
CINDER_POD="cinder-volume-lightbits-0"
PATCHED_FILE="lightos-patched.py"
MOUNT_NAME="patch1"

# Detect OS for sed compatibility
if [[ "$(uname)" == "Darwin" ]]; then
  SED_INPLACE=(-i '')
else
  SED_INPLACE=(-i)
fi

echo "=== [1/3] Lightbits Cinder patch for OCP ==="

# Check prerequisites
if ! command -v oc &>/dev/null; then
  echo "ERROR: oc not found in PATH"
  exit 1
fi

if ! command -v sed &>/dev/null; then
  echo "ERROR: sed not found in PATH"
  exit 1
fi

# Step 1: Fetch lightos.py from the Cinder pod
echo ""
echo "[1/3] Fetching lightos.py from $CINDER_POD..."
oc exec -n "$NAMESPACE" "$CINDER_POD" -- cat \
  /usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py > "$PATCHED_FILE"

if [ ! -s "$PATCHED_FILE" ]; then
  echo "ERROR: Failed to fetch lightos.py from $CINDER_POD"
  exit 1
fi

# Step 2: Apply host_ips patch
echo ""
echo "[2/3] Applying host_ips patch..."

if grep -q "host_ips" "$PATCHED_FILE"; then
  echo "WARNING: host_ips already present in lightos.py, skipping patch"
else
  sed "${SED_INPLACE[@]}" \
    "s/props\['found_dsc'\] = found_dsc/props['found_dsc'] = found_dsc\n            props['host_ips'] = [open('\/etc\/node-hostname').read().strip()]/" \
    "$PATCHED_FILE"

  if ! grep -q "host_ips" "$PATCHED_FILE"; then
    echo "ERROR: Failed to apply host_ips patch"
    exit 1
  fi
  echo "Patch applied successfully"
fi

# Step 3: Create ConfigMap and extraMount on OCP
echo ""
echo "[3/3] Creating ConfigMap and extraMount on OCP..."

oc create configmap lightos-connector-patch -n "$NAMESPACE" \
  --from-file=lightos.py="$PATCHED_FILE" \
  --dry-run=client -o yaml | oc apply -f -

oc get openstackcontrolplane "$CP_NAME" -n "$NAMESPACE" -o json | \
  python3 -c "
import json, sys
obj = json.load(sys.stdin)
mounts = obj['spec']['cinder']['template']['extraMounts']
# Remove existing patch mount if present (idempotent)
mounts = [m for m in mounts if m['name'] != '$MOUNT_NAME']
# Add patch mount
mounts.append({
  'name': '$MOUNT_NAME',
  'region': 'r1',
  'extraVol': [{
    'extraVolType': 'Internal',
    'propagation': ['CinderVolume', 'CinderBackup'],
    'mounts': [
      {
        'name': 'lightos-connector-patch',
        'mountPath': '/usr/lib/python3.9/site-packages/os_brick/initiator/connectors/lightos.py',
        'subPath': 'lightos.py'
      }
    ],
    'volumes': [
      {
        'name': 'lightos-connector-patch',
        'configMap': {'name': 'lightos-connector-patch'}
      }
    ]
  }]
})
obj['spec']['cinder']['template']['extraMounts'] = mounts
print(json.dumps(obj))
" | oc apply -f -

echo ""
echo "=== OCP Cinder patch complete ==="
echo ""
echo "Patched file saved as: $PATCHED_FILE"
echo ""
echo "Next steps:"
echo "  1. Copy $PATCHED_FILE to each EDPM node"
echo "  2. Run 02-edpm-cinder-patch.sh on each EDPM node"
echo "  3. Run 03-ocp-edpm-nova-patch.sh from this client"
