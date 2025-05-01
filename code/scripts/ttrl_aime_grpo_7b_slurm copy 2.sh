#!/bin/bash

#SBATCH --nodes=1                    # Request 1 node
#SBATCH --ntasks-per-node=1          # Run 1 primary task (this script) per node
#SBATCH --gres=gpu:4                 # Request 4 GPUs per node
#SBATCH --cpus-per-task=16           # Request CPUs for the main task
#SBATCH --mem=128G                   # Request memory
#SBATCH --time=1:00:00              # Request wall time
#SBATCH --job-name=ttrl_ray_aime_grpo_7b # Job name
#SBATCH --output=slurm_logs/ray_%x-%j.out # Standard output and error log
#SBATCH --partition=debug            # Specify the partition

set -x # Echo commands

# --- Cleanup function ---
# Ensures ray stop is attempted on exit/error
cleanup() {
    EXIT_CODE=$? # Capture exit code
    echo "--- Running Cleanup (Exit Code: $EXIT_CODE) ---"
    # Dump dashboard log on exit, especially if error occurred
    echo "--- Dumping Dashboard Log (/tmp/ray/session_latest/logs/dashboard.log) ---"
    cat /tmp/ray/session_latest/logs/dashboard.log || echo "Dashboard log not found or empty."
    echo "--- End Dashboard Log ---"

    # Removed RAY_PID killing logic

    echo "Attempting ray stop..."
    ray stop || echo "ray stop failed or Ray was not running."
    echo "Cleanup finished."
    # Exit with the original exit code
    exit $EXIT_CODE
}
trap cleanup EXIT SIGINT SIGTERM # Register cleanup function

# --- Load Modules ---
pip install grpcio --upgrade

# --- Install missing Ray dashboard dependencies (Temporary Workaround) ---
echo "Installing Ray dashboard dependencies..."
pip install aiohttp aiohttp_cors grpcio opencensus opencensus-ext-grpc opencensus-ext-prometheus prometheus_client
INSTALL_DEPS_EXIT_CODE=$?
if [ $INSTALL_DEPS_EXIT_CODE -ne 0 ]; then
    echo "Error: Failed to install Ray dashboard dependencies with exit code $INSTALL_DEPS_EXIT_CODE."
    exit 1 # trap will call cleanup
fi
# ----------------------------------------------------------------------

# TODO: Remove once we update the Docker container
# Navigate to the known code directory and install
CODE_DIR="/users/jhbotter/TTRL/code" # Explicitly define the code directory
echo "Changing directory to: ${CODE_DIR}"
cd "${CODE_DIR}"
if [ $? -ne 0 ]; then
    echo "Error: Failed to change directory to ${CODE_DIR}."
    exit 1 # trap will call cleanup
fi
pip install -e .
INSTALL_EXIT_CODE=$?
if [ $INSTALL_EXIT_CODE -ne 0 ]; then
    echo "Error: pip install -e . failed with exit code $INSTALL_EXIT_CODE."
    exit 1 # trap will call cleanup
fi


# --- Arguments passed from sbatch command line ---
# These are not used for the dummy job test, but keep for consistency
ROOT_DIR=$1
MODEL_DIR=$2
WANDB_KTY=$3

if [ -z "$ROOT_DIR" ] || [ -z "$MODEL_DIR" ] || [ -z "$WANDB_KTY" ]; then
  echo "Usage: sbatch $0 <root_dir> <model_dir> <wandb_key>"
  exit 1 # trap will call cleanup
fi
# ------------------------------------------------------------

# --- Get Head Node IP (Directly) ---
export HEAD_NODE_IP_ADDR=$(hostname -i) # Export so Python script can see it
export RAY_DASHBOARD_PORT=8265
export RAY_HEAD_PORT=6379
export SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-4}
# Export Dashboard Address for the submit script
export RAY_DASHBOARD_ADDRESS="http://$HEAD_NODE_IP_ADDR:$RAY_DASHBOARD_PORT"
# Export Working Directory for the submit script
export RAY_JOB_WORKING_DIR="${CODE_DIR}"

# Check if IP address was obtained
if [ -z "$HEAD_NODE_IP_ADDR" ]; then
  echo "Error: Could not obtain IP address using hostname -i"
  exit 1 # trap will call cleanup
fi

echo "Slurm Job ID: $SLURM_JOB_ID"
echo "Running on node: $SLURMD_NODENAME"
echo "Number of Nodes: $SLURM_NNODES"
echo "GPUs on Node: $SLURM_GPUS_ON_NODE"
echo "Head Node IP Address: $HEAD_NODE_IP_ADDR"
echo "Ray Head Port: $RAY_HEAD_PORT"
echo "Ray Dashboard Port: $RAY_DASHBOARD_PORT"
echo "Ray Dashboard Address: $RAY_DASHBOARD_ADDRESS"
echo "Ray Job Working Dir: $RAY_JOB_WORKING_DIR"

# --- Check /dev/shm Size ---
echo "--- Checking /dev/shm size ---"
df -h /dev/shm || echo "Failed to check /dev/shm size"
echo "--- End /dev/shm check ---"

# --- Create Directories ---
mkdir -p "${ROOT_DIR}/logs"
mkdir -p "${ROOT_DIR}/outputs"
mkdir -p slurm_logs

# --- Start Ray Head Node using Ray CLI (in background) ---
echo "Starting Ray Head via Ray CLI (ray start --head)..."
ray start --head \
    --node-ip-address="$HEAD_NODE_IP_ADDR" \
    --port="$RAY_HEAD_PORT" \
    --dashboard-host="0.0.0.0" \
    --dashboard-port="$RAY_DASHBOARD_PORT" \
    --num-gpus="$SLURM_GPUS_ON_NODE" \
    --include-dashboard=true \
    --disable-usage-stats \
    --block & # Run in background, --block is misleading here, it blocks the command itself if not backgrounded

RAY_START_PID=$! # Capture PID of the ray start command itself (optional, mainly for logging)
echo "Ray start command initiated (PID: $RAY_START_PID). Waiting for cluster..."

# Wait longer for the head node AND dashboard to initialize fully
# Ray start returns quickly, but cluster takes time. Increase sleep.
echo "Waiting 15 seconds for Ray head/dashboard (CLI) to initialize..."
sleep 15

# --- Check Ray Cluster Status ---
# Add retries for status check as cluster might take a moment
MAX_RETRIES=5
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ray status
    STATUS_EXIT_CODE=$?
    if [ $STATUS_EXIT_CODE -eq 0 ]; then
        echo "Ray status check successful."
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Ray status check failed (Attempt $RETRY_COUNT/$MAX_RETRIES). Retrying in 5 seconds..."
    sleep 5
done

if [ $STATUS_EXIT_CODE -ne 0 ]; then
    echo "Error: Ray status check failed after $MAX_RETRIES attempts."
    exit 1 # trap will call cleanup
fi

# --- Verify Dashboard API Endpoint with curl ---
echo "Verifying dashboard API endpoint with curl..."
# Use -v for verbose output to see connection attempt details
curl -v "$RAY_DASHBOARD_ADDRESS/api/jobs/"
CURL_EXIT_CODE=$?
if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "Error: curl command failed with exit code $CURL_EXIT_CODE. Cannot verify dashboard API endpoint."
    # Dump dashboard log immediately for context
    echo "--- Dumping Dashboard Log (/tmp/ray/session_latest/logs/dashboard.log) ---"
    cat /tmp/ray/session_latest/logs/dashboard.log || echo "Dashboard log not found or empty."
    echo "--- End Dashboard Log ---"
    exit 1 # Make this fatal now, as job submission will fail
else
    echo "Curl check finished (check output for HTTP status code)."
fi
sleep 5
# --------------------------------------------

# --- Submit DUMMY Job to Ray Cluster using Ray CLI ---
echo "Submitting DUMMY job via Ray CLI (ray job submit)... (This will block until job finishes)"

# Use the Ray CLI to submit the job
# --address uses the exported RAY_DASHBOARD_ADDRESS
# --working-dir uses the exported RAY_JOB_WORKING_DIR
# -- specifies the start of the entrypoint command
ray job submit --address "$RAY_DASHBOARD_ADDRESS" \
               --working-dir "$RAY_JOB_WORKING_DIR" \
               -- python scripts/dummy_job.py

JOB_SUBMIT_EXIT_CODE=$?

# --- Check Job Submission Exit Code ---
if [ $JOB_SUBMIT_EXIT_CODE -eq 0 ]; then
    echo "Ray CLI job submission reported success." # Updated message
else
    echo "Error: Ray CLI job submission failed with exit code $JOB_SUBMIT_EXIT_CODE." # Updated message
    # No need to exit 1 here, the trap will handle it and dump logs
    # exit 1
fi

echo "Script finished normally."
# Exit trap will run the cleanup function now.
