#!/bin/bash

# Generate unique identifiers
RANDOM_ID=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
UNIQUE_PREFIX="winvm-${RANDOM_ID}-${TIMESTAMP}"

# Use the current project and authentication
CURRENT_PROJECT=$(gcloud config get-value project)
echo "Using project: $CURRENT_PROJECT"

# First, try to determine the allowed locations from organization policy
echo "Checking organization policy for allowed locations..."
ALLOWED_LOCATIONS=$(gcloud resource-manager org-policies describe constraints/gcp.resourceLocations --effective --project="$CURRENT_PROJECT" --format="value(listPolicy.allowedValues)" 2>/dev/null)

# Set of potential regions to try (will be filtered based on org policy if available)
ALL_REGIONS=("us-west1" "us-west2" "us-west3" "us-west4" "us-central1" "us-east1" "us-east4" "us-east5" "us-south1" "europe-west1" "europe-west2" "europe-west3" "europe-west4" "europe-west6" "europe-west9" "europe-west10" "europe-west12" "europe-north1" "europe-central2" "europe-southwest1" "asia-east1" "asia-east2" "asia-northeast1" "asia-northeast2" "asia-northeast3" "asia-southeast1")

# If we have org policy information, filter regions based on it
if [ -n "$ALLOWED_LOCATIONS" ]; then
    echo "Found organization policy with allowed locations: $ALLOWED_LOCATIONS"
    FILTERED_REGIONS=()
    for REGION in "${ALL_REGIONS[@]}"; do
        if [[ "$ALLOWED_LOCATIONS" == *"$REGION"* ]]; then
            FILTERED_REGIONS+=("$REGION")
        fi
    done
    
    # If we found allowed regions, use them
    if [ ${#FILTERED_REGIONS[@]} -gt 0 ]; then
        echo "Using regions allowed by org policy: ${FILTERED_REGIONS[*]}"
        REGIONS_TO_TRY=("${FILTERED_REGIONS[@]}")
    else
        echo "No matching regions found in org policy, will try standard regions"
        REGIONS_TO_TRY=("${ALL_REGIONS[@]}")
    fi
else
    echo "No explicit resource location constraints found, will try standard regions"
    REGIONS_TO_TRY=("${ALL_REGIONS[@]}")
fi

# Try to create a small test VM in each region to verify permissions
ZONE_VALID=false

for REGION in "${REGIONS_TO_TRY[@]}"; do
    echo "Trying region: $REGION"
    # Get available zones in this region
    ZONES=$(gcloud compute zones list --filter="region:$REGION" --format="value(name)")
    
    for ZONE in $ZONES; do
        echo "Testing zone: $ZONE"
        
        # Try to create a small test instance
        TEST_VM_NAME="test-${RANDOM_ID}-$(date +%s)"
        TEST_RESULT=$(gcloud compute instances create "$TEST_VM_NAME" \
            --zone="$ZONE" \
            --machine-type="f1-micro" \
            --image-family="debian-10" \
            --image-project="debian-cloud" \
            --no-restart-on-failure \
            --metadata="enable-oslogin=true" \
            --boot-disk-size="10GB" \
            --format="none" 2>&1)
        
        # If creation was successful or we got a quota error, we have the right permissions
        if [ $? -eq 0 ]; then
            echo "Successfully created test VM in $ZONE"
            # Cleanup test VM
            gcloud compute instances delete "$TEST_VM_NAME" --zone="$ZONE" --quiet >/dev/null 2>&1
            
            ZONE_VALID=true
            VM_ZONE="$ZONE"
            break 2  # Break out of both loops
        else
            # If the error is about resource locations, continue to next zone
            if [[ "$TEST_RESULT" == *"violates constraint constraints/gcp.resourceLocations"* ]]; then
                echo "Zone $ZONE not allowed by organization policy"
            # If quota error or other errors that suggest we can create VMs with different params
            elif [[ "$TEST_RESULT" == *"quota"* ]] || [[ "$TEST_RESULT" == *"QUOTA"* ]]; then
                echo "Zone $ZONE has quota issues but is allowed - will use this zone"
                ZONE_VALID=true
                VM_ZONE="$ZONE"
                break 2  # Break out of both loops
            else
                echo "Other error in zone $ZONE: ${TEST_RESULT:0:100}..."
            fi
        fi
    done
done

if [ "$ZONE_VALID" != "true" ]; then
    echo "Error: Could not find a valid zone for VM creation. Please check project permissions and constraints."
    exit 1
fi

echo "Using zone: $VM_ZONE for VM creation"

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