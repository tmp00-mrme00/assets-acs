#!/bin/bash

# Use the current project and authentication
PROJECT=$(gcloud config get-value project)
echo "Using project: $PROJECT"

# Find allowed zones in the project
echo "Finding allowed zones for your project..."
AVAILABLE_ZONES=$(gcloud compute zones list --format="value(name)" --limit=10)

# Try each zone until one works
for ZONE in $AVAILABLE_ZONES; do
  echo "Testing zone: $ZONE"
  if gcloud compute instances list --zones="$ZONE" >/dev/null 2>&1; then
    echo "Found valid zone: $ZONE"
    ZONE_FOUND=true
    break
  fi
done

if [ "$ZONE_FOUND" != "true" ]; then
  echo "Error: Could not find a valid zone. Please check project permissions."
  exit 1
fi

# Create a unique instance name
INSTANCE_NAME="win-vm-$(date +%Y%m%d%H%M%S)"
echo "Creating VM: $INSTANCE_NAME in zone: $ZONE"

# Create the VM
gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="n1-standard-1" \
    --network-tier="PREMIUM" \
    --subnet="default" \
    --metadata="enable-oslogin=true" \
    --maintenance-policy="MIGRATE" \
    --image-project="windows-cloud" \
    --image-family="windows-server-2022-dc-core" \
    --boot-disk-size="50GB" \
    --boot-disk-type="pd-balanced" \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring

# Wait for VM to be ready
echo "Waiting for VM to initialize (30 seconds)..."
sleep 30

# Get the external IP address
EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)

# Print the information
echo "========================================"
echo "WINDOWS VM CREATION COMPLETE"
echo "========================================"
echo "VM Name: $INSTANCE_NAME"
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "External IP Address: $EXTERNAL_IP"
echo "Authentication: Use your Google account credentials."
echo "========================================"