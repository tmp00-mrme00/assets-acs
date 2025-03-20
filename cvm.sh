#!/bin/bash

# Generate unique identifiers
RANDOM_ID=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
UNIQUE_PREFIX="winvm-${RANDOM_ID}-${TIMESTAMP}"

# Use the current project and authentication
CURRENT_PROJECT=$(gcloud config get-value project)
echo "Using project: $CURRENT_PROJECT"

# Find allowed zones in the project
echo "Finding allowed zones for your project..."
ZONE_LIST=$(gcloud compute zones list --format="value(name)" --limit=15)

# Try each zone until one works
ZONE_VALID=false
for TEST_ZONE in $ZONE_LIST; do
  echo "Testing zone: $TEST_ZONE"
  if gcloud compute instances list --zones="$TEST_ZONE" >/dev/null 2>&1; then
    echo "Found valid zone: $TEST_ZONE"
    ZONE_VALID=true
    VM_ZONE="$TEST_ZONE"
    break
  fi
done

if [ "$ZONE_VALID" != "true" ]; then
  echo "Error: Could not find a valid zone. Please check project permissions."
  exit 1
fi

# Find a valid Windows image to use
echo "Finding available Windows images..."
# Try these image families in order of preference
IMAGE_FAMILIES=("windows-server-2022-dc" "windows-server-2019-dc" "windows-server-2016-dc" "windows-server-2012-r2-dc")
IMAGE_FOUND=false

for FAMILY in "${IMAGE_FAMILIES[@]}"; do
  echo "Checking image family: $FAMILY"
  IMAGE_INFO=$(gcloud compute images describe-from-family $FAMILY --project=windows-cloud --format="value(name)" 2>/dev/null)
  if [ -n "$IMAGE_INFO" ]; then
    echo "Using image family: $FAMILY"
    IMAGE_FAMILY="$FAMILY"
    IMAGE_FOUND=true
    break
  fi
done

if [ "$IMAGE_FOUND" != "true" ]; then
  echo "Falling back to listing available Windows images..."
  # Get the most recent Windows Server image
  LATEST_IMAGE=$(gcloud compute images list --project=windows-cloud --filter="name~'windows-server'" --sort-by=~creationTimestamp --limit=1 --format="value(name)")
  if [ -n "$LATEST_IMAGE" ]; then
    echo "Using specific image: $LATEST_IMAGE"
    USE_SPECIFIC_IMAGE=true
  else
    echo "Error: No Windows Server images available. Please check your permissions."
    exit 1
  fi
fi

# Create a unique instance name
VM_NAME="${UNIQUE_PREFIX}"
echo "Creating VM: $VM_NAME in zone: $VM_ZONE"

# Create the VM command
if [ "$USE_SPECIFIC_IMAGE" == "true" ]; then
  # Use specific image
  gcloud compute instances create "$VM_NAME" \
      --zone="$VM_ZONE" \
      --machine-type="n1-standard-1" \
      --network-tier="PREMIUM" \
      --subnet="default" \
      --metadata="enable-oslogin=true" \
      --maintenance-policy="MIGRATE" \
      --image-project="windows-cloud" \
      --image="$LATEST_IMAGE" \
      --boot-disk-size="50GB" \
      --boot-disk-type="pd-balanced" \
      --no-shielded-secure-boot \
      --shielded-vtpm \
      --shielded-integrity-monitoring
else
  # Use image family
  gcloud compute instances create "$VM_NAME" \
      --zone="$VM_ZONE" \
      --machine-type="n1-standard-1" \
      --network-tier="PREMIUM" \
      --subnet="default" \
      --metadata="enable-oslogin=true" \
      --maintenance-policy="MIGRATE" \
      --image-project="windows-cloud" \
      --image-family="$IMAGE_FAMILY" \
      --boot-disk-size="50GB" \
      --boot-disk-type="pd-balanced" \
      --no-shielded-secure-boot \
      --shielded-vtpm \
      --shielded-integrity-monitoring
fi

# Check if VM was created successfully
if [ $? -ne 0 ]; then
  echo "Error: Failed to create VM. Please check permissions and quotas."
  exit 1
fi

# Wait for VM to be ready
echo "Waiting for VM to initialize (45 seconds)..."
sleep 45

# Get the external IP address with retry
MAX_RETRIES=3
for ((i=1; i<=MAX_RETRIES; i++)); do
  VM_IP=$(gcloud compute instances describe "$VM_NAME" --zone="$VM_ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
  if [ -n "$VM_IP" ]; then
    break
  fi
  echo "Waiting for IP address to be assigned (attempt $i/$MAX_RETRIES)..."
  sleep 10
done

# Print the information
echo "========================================"
echo "WINDOWS VM CREATION COMPLETE"
echo "========================================"
echo "VM Name: $VM_NAME"
echo "Project: $CURRENT_PROJECT"
echo "Zone: $VM_ZONE"
echo "External IP Address: $VM_IP"
echo "Authentication: Use your Google account credentials."
echo "========================================"
echo "Remote Desktop Info:"
echo "Username: Your Google Identity"
echo "Password: Your Google Authentication"
echo "========================================"