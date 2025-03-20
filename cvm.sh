#!/bin/bash

# Dynamically determine the project ID
PROJECT=$(gcloud config get-value project)

# Check if a project is configured
if [ -z "$PROJECT" ]; then
  echo "Error: No Google Cloud project is configured. Please run 'gcloud config set project <your_project_id>'."
  exit 1
fi

# Set variables
# **IMPORTANT: Change the ZONE to a location allowed by your project's policies**
ZONE="us-central1-a"  # Example: Change to a valid zone for your project
INSTANCE_NAME="instance-20250320-160519"

# Create the VM (using your provided command, slightly modified for clarity)
gcloud compute instances create "$INSTANCE_NAME" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --machine-type="n1-standard-1" \
    --network-interface="network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default" \
    --metadata="enable-osconfig=TRUE,enable-oslogin=true" \
    --maintenance-policy="MIGRATE" \
    --provisioning-model="STANDARD" \
    --service-account="235271429094-compute@developer.gserviceaccount.com" \
    --scopes="https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append" \
    --create-disk="auto-delete=yes,boot=yes,device-name=$INSTANCE_NAME,image=projects/windows-cloud/global/images/windows-server-2025-dc-v20250312,mode=rw,size=50,type=pd-balanced" \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels="goog-ops-agent-policy=v2-x86-template-1-4-0,goog-ec-src=vm_add-gcloud" \
    --reservation-affinity="any"

# Wait for the VM to be ready (optional, but recommended)
echo "Waiting for VM to start..."
gcloud compute instances wait-until-running "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT"

# Get the external IP address
EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

# Print the information
echo "VM Name: $INSTANCE_NAME"
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "Authentication Method: Google Account (enable-oslogin=true)"
echo "External IP Address: $EXTERNAL_IP"
echo "To login, use your Google account credentials."

# The rest of your commands (ops-agents policies, resource policies)
# **IMPORTANT:  The following commands may fail if the OS Config API is not enabled
# and you don't have permissions to enable it.  Consider removing them if necessary.**
printf 'agentsRule:\n  packageState: installed\n  version: latest\ninstanceFilter:\n  inclusionLabels:\n  - labels:\n      goog-ops-agent-policy: v2-x86-template-1-4-0\n' > config.yaml && gcloud compute instances ops-agents policies create goog-ops-agent-v2-x86-template-1-4-0-us-east1-c --project="$PROJECT" --zone="$ZONE" --file=config.yaml && gcloud compute resource-policies create snapshot-schedule default-schedule-1 --project="$PROJECT" --region=us-east1 --max-retention-days=14 --on-source-disk-delete=keep-auto-snapshots --daily-schedule --start-time=07:00 && gcloud compute disks add-resource-policies instance-20250320-160519 --project="$PROJECT" --zone="$ZONE" --resource-policies=projects/"$PROJECT"/regions/us-east1/resourcePolicies/default-schedule-1