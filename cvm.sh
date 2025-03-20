#!/bin/bash
# filepath: /Users/m/code/mukta-deploy/dep-scripts/cvm.sh

# Generate unique identifiers
RANDOM_ID=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
UNIQUE_PREFIX="instance-${TIMESTAMP}-${RANDOM_ID}"

# Use the current project and authentication
CURRENT_PROJECT=$(gcloud config get-value project)
echo "Using project: $CURRENT_PROJECT"

# Determine allowed regions from org policy
echo "Checking organization policy for allowed locations..."
ALLOWED_LOCATIONS=$(gcloud resource-manager org-policies describe constraints/gcp.resourceLocations \
  --effective --project="$CURRENT_PROJECT" --format="value(listPolicy.allowedValues)" 2>/dev/null)

ALL_REGIONS=("us-west1" "us-west2" "us-west3" "us-west4" "us-central1" "us-east1" "us-east4" "us-east5" "us-south1" "europe-west1" "europe-west2" "europe-west3" "europe-west4" "europe-west6" "europe-west9" "europe-west10" "europe-west12" "europe-north1" "europe-central2" "europe-southwest1" "asia-east1" "asia-east2" "asia-northeast1" "asia-northeast2" "asia-northeast3" "asia-southeast1")

if [ -n "$ALLOWED_LOCATIONS" ]; then
  echo "Found organization policy with allowed locations: $ALLOWED_LOCATIONS"
  FILTERED_REGIONS=()
  for REGION in "${ALL_REGIONS[@]}"; do
    if [[ "$ALLOWED_LOCATIONS" == *"$REGION"* ]] || \
       ([[ "$REGION" == *"us-central"* ]] && [[ "$ALLOWED_LOCATIONS" == *"us-central"* ]]) || \
       ([[ "$REGION" == *"us-"* ]] && [[ "$ALLOWED_LOCATIONS" == *";us;"* ]]) || \
       ([[ "$REGION" == *"europe-"* ]] && [[ "$ALLOWED_LOCATIONS" == *";europe;"* ]]); then
      FILTERED_REGIONS+=("$REGION")
    fi
  done
  if [ ${#FILTERED_REGIONS[@]} -gt 0 ]; then
    echo "Using regions allowed by org policy: ${FILTERED_REGIONS[*]}"
    REGIONS_TO_TRY=("${FILTERED_REGIONS[@]}")
  else
    echo "No matching regions in org policy; will try all regions."
    REGIONS_TO_TRY=("${ALL_REGIONS[@]}")
  fi
else
  echo "No explicit resource location constraints found; will try all regions."
  REGIONS_TO_TRY=("${ALL_REGIONS[@]}")
fi

# Test zones for VM creation by attempting a small test instance
ZONE_VALID=false
for REGION in "${REGIONS_TO_TRY[@]}"; do
  echo "Trying region: $REGION"
  ZONES=$(gcloud compute zones list --filter="region:$REGION" --format="value(name)")
  for ZONE in $ZONES; do
    echo "Testing zone: $ZONE"
    TEST_VM_NAME="test-${RANDOM_ID}-$(date +%s)"
    echo "Attempting test VM $TEST_VM_NAME in $ZONE..."
    gcloud compute instances create "$TEST_VM_NAME" \
      --zone="$ZONE" \
      --machine-type="f1-micro" \
      --image-family="debian-10" \
      --image-project="debian-cloud" \
      --no-restart-on-failure \
      --metadata="enable-oslogin=true" \
      --boot-disk-size="30GB" \
      --quiet 2>&1 > /tmp/vm_create_output.txt
    CREATE_RESULT=$?
    TEST_RESULT=$(cat /tmp/vm_create_output.txt)
    if [ $CREATE_RESULT -eq 0 ]; then
      echo "Test VM created successfully in $ZONE"
      gcloud compute instances delete "$TEST_VM_NAME" --zone="$ZONE" --quiet >/dev/null 2>&1
      ZONE_VALID=true
      VM_ZONE="$ZONE"
      break 2
    else
      if [[ "$TEST_RESULT" == *"violates constraint constraints/gcp.resourceLocations"* ]]; then
        echo "Zone $ZONE not allowed by organization policy"
      elif [[ "$TEST_RESULT" == *"quota"* ]] || [[ "$TEST_RESULT" == *"QUOTA"* ]]; then
        echo "Zone $ZONE has quota issues but is allowed—using this zone"
        ZONE_VALID=true
        VM_ZONE="$ZONE"
        break 2
      elif [[ "$TEST_RESULT" == *"WARNING: You have selected a disk size of under"* ]] && \
           [[ "$TEST_RESULT" != *"FAILED:"* ]] && [[ "$TEST_RESULT" != *"ERROR:"* ]]; then
        echo "Zone $ZONE shows only a disk size warning; using this zone"
        ZONE_VALID=true
        VM_ZONE="$ZONE"
        break 2
      else
        echo "Error in zone $ZONE: $TEST_RESULT"
      fi
    fi
  done
done

if [ "$ZONE_VALID" != "true" ]; then
  echo "No valid zone found; defaulting to us-central1-a"
  VM_ZONE="us-central1-a"
fi
echo "Using zone: $VM_ZONE for VM creation"

# Choose a valid Windows image using image families in order of preference
echo "Finding available Windows images..."
IMAGE_FAMILIES=("windows-server-2025-dc" "windows-server-2022-dc" "windows-server-2019-dc" "windows-server-2016-dc" "windows-server-2012-r2-dc")
IMAGE_FOUND=false
for FAMILY in "${IMAGE_FAMILIES[@]}"; do
  echo "Checking image family: $FAMILY"
  IMAGE_INFO=$(gcloud compute images describe-from-family "$FAMILY" --project=windows-cloud --format="value(name)" 2>/dev/null)
  if [ -n "$IMAGE_INFO" ]; then
    echo "Using image: $IMAGE_INFO from family: $FAMILY"
    WINDOWS_IMAGE="$IMAGE_INFO"
    IMAGE_FOUND=true
    break
  fi
done
if [ "$IMAGE_FOUND" != "true" ]; then
  echo "Falling back to most recent Windows image..."
  WINDOWS_IMAGE=$(gcloud compute images list --project=windows-cloud --filter="name~'windows-server'" --sort-by=~creationTimestamp --limit=1 --format="value(name)")
  if [ -n "$WINDOWS_IMAGE" ]; then
    echo "Using specific image: $WINDOWS_IMAGE"
  else
    echo "Error: No Windows images available."
    exit 1
  fi
fi

# Retrieve the default Compute Engine service account
DEFAULT_SA=$(gcloud iam service-accounts list --filter="displayName:Compute Engine default service account" --format="value(email)" --limit=1)
if [ -z "$DEFAULT_SA" ]; then
  PROJECT_NUMBER=$(gcloud projects describe "$CURRENT_PROJECT" --format="value(projectNumber)")
  DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
fi
echo "Using service account: $DEFAULT_SA"

# Create a unique instance name for the production VM
VM_NAME="${UNIQUE_PREFIX}"
echo "Creating Windows VM: $VM_NAME in zone: $VM_ZONE"

# Create the Windows VM with options matching the provided sample
gcloud compute instances create "$VM_NAME" \
  --project="$CURRENT_PROJECT" \
  --zone="$VM_ZONE" \
  --machine-type="e2-medium" \
  --network-interface="network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default" \
  --metadata="enable-osconfig=TRUE,enable-oslogin=true" \
  --maintenance-policy="MIGRATE" \
  --provisioning-model="STANDARD" \
  --service-account="$DEFAULT_SA" \
  --scopes="https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append" \
  --create-disk="auto-delete=yes,boot=yes,device-name=$VM_NAME,image=projects/windows-cloud/global/images/$WINDOWS_IMAGE,mode=rw,size=50,type=pd-balanced" \
  --no-shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --labels="goog-ops-agent-policy=v2-x86-template-1-4-0,goog-ec-src=vm_add-gcloud" \
  --reservation-affinity=any

if [ $? -ne 0 ]; then
  echo "Error: Failed to create Windows VM. Exiting."
  exit 1
fi

# Wait for the VM to become fully operational
echo "Waiting for VM to initialize (60 seconds)..."
sleep 60

# Retrieve the external IP address (with a few retries)
MAX_RETRIES=3
for ((i=1; i<=MAX_RETRIES; i++)); do
  VM_IP=$(gcloud compute instances describe "$VM_NAME" --zone="$VM_ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
  if [ -n "$VM_IP" ]; then
    break
  fi
  echo "Waiting for IP assignment (attempt $i/$MAX_RETRIES)..."
  sleep 10
done

# Create ops-agent configuration file
printf 'agentsRule:\n  packageState: installed\n  version: latest\ninstanceFilter:\n  inclusionLabels:\n  - labels:\n      goog-ops-agent-policy: v2-x86-template-1-4-0\n' > config.yaml

# Use a policy name that includes the zone for clarity
POLICY_NAME="goog-ops-agent-v2-x86-template-1-4-0-${VM_ZONE}"
gcloud compute instances ops-agents policies create "$POLICY_NAME" \
  --project="$CURRENT_PROJECT" \
  --zone="$VM_ZONE" \
  --file=config.yaml || echo "Warning: Ops-agent policy creation skipped."

# Print final VM details
echo "========================================"
echo "WINDOWS VM CREATION COMPLETE"
echo "VM Name: $VM_NAME"
echo "Project: $CURRENT_PROJECT"
echo "Zone: $VM_ZONE"
echo "External IP Address: $VM_IP"
echo "Remote Desktop Info:"
echo "  Username: Your Google Identity"
echo "  Password: Your Google Authentication"
echo "========================================"