#!/bin/bash

# Dynamically determine the project ID
PROJECT=$(gcloud config get-value project)

# Check if a project is configured
if [ -z "$PROJECT" ]; then
  echo "Error: No Google Cloud project is configured. Please run 'gcloud config set project <your_project_id>'."
  exit 1
fi

# Find allowed zones in the project
echo "Finding allowed zones for your project..."
# Try to get a list of zones and select the first one that works
AVAILABLE_ZONES=$(gcloud compute zones list --format="value(name)" --limit=10)

# Variable to track if we found a working zone
ZONE_FOUND=false

for ZONE in $AVAILABLE_ZONES; do
  echo "Testing zone: $ZONE"
  # Try to validate the zone by listing instances in it
  if gcloud compute instances list --zones="$ZONE" --project="$PROJECT" >/dev/null 2>&1; then
    echo "Found valid zone: $ZONE"
    ZONE_FOUND=true
    break
  fi
done

if [ "$ZONE_FOUND" = false ]; then
  echo "Error: Could not find a valid zone for your project. Please specify a zone manually."
  exit 1
fi

INSTANCE_NAME="windows-vm-$(date +%Y%m%d%H%M%S)"
echo "Using zone: $ZONE for instance: $INSTANCE_NAME"

# Create the VM
echo "Creating VM..."
gcloud compute instances create "$INSTANCE_NAME" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --machine-type="n1-standard-1" \
    --network-interface="network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default" \
    --metadata="enable-osconfig=TRUE,enable-oslogin=true" \
    --maintenance-policy="MIGRATE" \
    --provisioning-model="STANDARD" \
    --scopes="https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append" \
    --create-disk="auto-delete=yes,boot=yes,device-name=$INSTANCE_NAME,image=projects/windows-cloud/global/images/windows-server-2022-dc-v20240212,mode=rw,size=50,type=pd-balanced" \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --reservation-affinity="any"

# Simple wait instead of wait-until-running
echo "Waiting for VM to start (30 seconds)..."
sleep 30

# Get the external IP address
EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)

# Print the information
echo "========================================"
echo "VM CREATION COMPLETE"
echo "========================================"
echo "VM Name: $INSTANCE_NAME"
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "Authentication Method: Google Account (enable-oslogin=true)"
echo "External IP Address: $EXTERNAL_IP"
echo "To login, use your Google account credentials."
echo "========================================"