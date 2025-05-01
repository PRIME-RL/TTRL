#!/bin/bash

#SBATCH --nodes=1                    # Request 1 node
#SBATCH --ntasks-per-node=1          # Run 1 primary task (this script) per node
#SBATCH --gres=gpu:4                 # Request 4 GPUs per node
#SBATCH --cpus-per-task=16           # Request CPUs for the main task
#SBATCH --mem=128G                   # Request memory
#SBATCH --time=1:00:00              # Request wall time
#SBATCH --job-name=ttrl_ray_aime_grpo_7b # Job name
#SBATCH --output=slurm_logs/%x-%j.out # Standard output and error log
#SBATCH --partition=debug            # Specify the partition

set -x # Echo commands

# --- Cleanup function ---
cleanup() {
    EXIT_CODE=$? # Capture exit code
    echo "--- Running Cleanup (Exit Code: $EXIT_CODE) ---"
    echo "--- Dumping Dashboard Log (/tmp/ray/session_latest/logs/dashboard.log) ---"
    cat /tmp/ray/session_latest/logs/dashboard.log || echo "Dashboard log not found or empty."
    echo "--- End Dashboard Log ---"
    echo "Attempting ray stop..."
    ray stop || echo "ray stop failed or Ray was not running."
    echo "Cleanup finished."
    exit $EXIT_CODE
}
trap cleanup EXIT SIGINT SIGTERM

# --- Upgrade grpcio ---
pip install grpcio --upgrade

# --- Install missing Ray dashboard dependencies ---
echo "Installing Ray dashboard dependencies..."
pip install aiohttp aiohttp_cors grpcio opencensus opencensus-ext-grpc opencensus-ext-prometheus prometheus_client
INSTALL_DEPS_EXIT_CODE=$?
if [ $INSTALL_DEPS_EXIT_CODE -ne 0 ]; then
    echo "Error: Failed to install Ray dashboard dependencies with exit code $INSTALL_DEPS_EXIT_CODE."
    exit 1
fi

# --- Install Project Code ---
CODE_DIR="/users/jhbotter/TTRL/code"
echo "Changing directory to: ${CODE_DIR}"
cd "${CODE_DIR}"
if [ $? -ne 0 ]; then
    echo "Error: Failed to change directory to ${CODE_DIR}."
    exit 1
fi
pip install -e .
INSTALL_EXIT_CODE=$?
if [ $INSTALL_EXIT_CODE -ne 0 ]; then
    echo "Error: pip install -e . failed with exit code $INSTALL_EXIT_CODE."
    exit 1
fi

# --- Arguments ---
ROOT_DIR=$1
MODEL_DIR=$2
WANDB_KTY=$3
if [ -z "$ROOT_DIR" ] || [ -z "$MODEL_DIR" ] || [ -z "$WANDB_KTY" ]; then
  echo "Usage: sbatch $0 <root_dir> <model_dir> <wandb_key>"
  exit 1
fi

# --- Environment Setup ---
export HEAD_NODE_IP_ADDR=$(hostname -i)
export RAY_DASHBOARD_PORT=8265
export RAY_HEAD_PORT=6379
export SLURM_GPUS_ON_NODE=${SLURM_GPUS_ON_NODE:-4}
export RAY_DASHBOARD_ADDRESS="http://$HEAD_NODE_IP_ADDR:$RAY_DASHBOARD_PORT"
export RAY_JOB_WORKING_DIR="${CODE_DIR}"

if [ -z "$HEAD_NODE_IP_ADDR" ]; then
  echo "Error: Could not obtain IP address using hostname -i"
  exit 1
fi

echo "Slurm Job ID: $SLURM_JOB_ID"
echo "Running on node: $SLURMD_NODENAME"
echo "Head Node IP Address: $HEAD_NODE_IP_ADDR"
echo "Ray Dashboard Address: $RAY_DASHBOARD_ADDRESS"
echo "Ray Job Working Dir: $RAY_JOB_WORKING_DIR"

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
    --block &

RAY_START_PID=$!
echo "Ray start command initiated (PID: $RAY_START_PID). Assuming it will be ready shortly..."
sleep 5

# # --- Verify Dashboard API Endpoint with curl (minimal check) ---
# # Wait a very short time, then check if dashboard is minimally responsive
# sleep 5 # Reduced sleep, adjust if needed, or remove if confident
# echo "Verifying dashboard API endpoint with curl..."
# curl -v --fail --max-time 10 "$RAY_DASHBOARD_ADDRESS/api/jobs/" # Added --fail and --max-time
# CURL_EXIT_CODE=$?
# if [ $CURL_EXIT_CODE -ne 0 ]; then
#     echo "Error: curl command failed with exit code $CURL_EXIT_CODE. Cannot verify dashboard API endpoint."
#     echo "--- Dumping Dashboard Log (/tmp/ray/session_latest/logs/dashboard.log) ---"
#     cat /tmp/ray/session_latest/logs/dashboard.log || echo "Dashboard log not found or empty."
#     echo "--- End Dashboard Log ---"
#     exit 1
# else
#     echo "Curl check successful (HTTP 200 OK received)."
# fi

# --- Submit DUMMY Job to Ray Cluster using Ray CLI ---
echo "Submitting DUMMY job via Ray CLI (ray job submit)... (This will block until job finishes)"
ray job submit --address "$RAY_DASHBOARD_ADDRESS" \
               --working-dir "$RAY_JOB_WORKING_DIR" \
               -- python scripts/dummy_job.py
JOB_SUBMIT_EXIT_CODE=$?

# --- Check Job Submission Exit Code ---
if [ $JOB_SUBMIT_EXIT_CODE -eq 0 ]; then
    echo "Ray CLI job submission reported success."
else
    echo "Error: Ray CLI job submission failed with exit code $JOB_SUBMIT_EXIT_CODE."
fi

echo "Script finished normally."
# Exit trap will run the cleanup function now.
