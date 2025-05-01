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
# Ensures Ray starter script is killed and ray stop is attempted on exit/error
cleanup() {
    EXIT_CODE=$? # Capture exit code
    echo "--- Running Cleanup (Exit Code: $EXIT_CODE) ---"
    # Dump dashboard log on exit, especially if error occurred
    echo "--- Dumping Dashboard Log (/tmp/ray/session_latest/logs/dashboard.log) ---"
    cat /tmp/ray/session_latest/logs/dashboard.log || echo "Dashboard log not found or empty."
    echo "--- End Dashboard Log ---"

    if [[ -n "$RAY_PID" ]] && ps -p $RAY_PID > /dev/null; then
        echo "Killing Python Ray starter script (PID $RAY_PID)..."
        # Send SIGTERM first, then SIGKILL if it doesn't exit
        kill $RAY_PID
        sleep 5
        if ps -p $RAY_PID > /dev/null; then
            echo "Starter script still running, sending SIGKILL..."
            kill -9 $RAY_PID
            sleep 2
        fi
    fi
    echo "Attempting ray stop..."
    ray stop || echo "ray stop failed or Ray was not running."
    echo "Cleanup finished."
    # Exit with the original exit code
    exit $EXIT_CODE
}
trap cleanup EXIT SIGINT SIGTERM # Register cleanup function

# --- Version Check ---
pip install grpcio --upgrade
echo "--- Version Check ---"
ray --version || echo "Failed to get Ray version"
pip show grpcio ray || echo "Failed to get pip package info"
echo "--- End Version Check ---"

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

# # --- Simple Ray Init Test ---
# echo "--- Running Simple Ray Init Test ---"
# python -c "import ray; ray.init(); print('Simple Ray initialized successfully'); ray.shutdown()"
# INIT_TEST_EXIT_CODE=$?
# if [ $INIT_TEST_EXIT_CODE -ne 0 ]; then
#     echo "Error: Simple Ray init test failed with exit code $INIT_TEST_EXIT_CODE."
#     exit 1 # trap will call cleanup
# fi
# echo "--- Simple Ray Init Test Successful ---"
# # ----------------------------


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

# --- Define log file for Python Ray starter script ---
RAY_STARTER_LOG="slurm_logs/ray_starter_python_${SLURM_JOB_ID}.log"

# --- Start Ray Head Node using Python Script (in background) ---
echo "Starting Ray Head via Python script (scripts/start_ray_head.py)... Logging to ${RAY_STARTER_LOG}"
python scripts/start_ray_head.py > "${RAY_STARTER_LOG}" 2>&1 &
RAY_PID=$! # Get the PID of the Python script

# Wait longer for the head node AND dashboard to initialize fully
echo "Waiting 5 seconds for Ray head/dashboard (Python script) to initialize..."
sleep 5

# --- Check if Python Ray starter script is running ---
if ! ps -p $RAY_PID > /dev/null; then
   echo "Error: Python Ray starter script (PID $RAY_PID) terminated prematurely."
   echo "--- Python Ray Starter Log ---"
   cat "${RAY_STARTER_LOG}" || echo "Python Ray starter log not found or empty."
   exit 1 # trap will call cleanup (which dumps dashboard log)
fi
echo "Python Ray starter script (PID $RAY_PID) is running."

# --- Dump Python Ray starter log ---
echo "--- Dumping Python Ray Starter Log ---"
cat "${RAY_STARTER_LOG}" || echo "Python Ray starter log not found or empty."

# --- Check Ray Cluster Status ---
ray status
if [ $? -ne 0 ]; then
    echo "Error: Ray status check failed even though Python starter script is running."
    exit 1 # trap will call cleanup
fi
echo "Ray status check successful."
sleep 5

# --- Verify Dashboard API Endpoint with curl ---
echo "Verifying dashboard API endpoint with curl..."
# Use -v for verbose output to see connection attempt details
curl -v "http://$HEAD_NODE_IP_ADDR:$RAY_DASHBOARD_PORT/api/jobs/"
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

# # --- Submit DUMMY Job to Ray Cluster using Python SDK ---
# echo "Submitting DUMMY job via Python script (scripts/submit_ray_job.py)... (This will block until job finishes)"

# # Define the entrypoint command to execute the dummy script file
# # Ensure the path is correct relative to the RAY_JOB_WORKING_DIR
# DUMMY_CMD="python scripts/dummy_job.py"

# # Execute the submission script, passing the command components as separate arguments
# python scripts/submit_ray_job.py ${DUMMY_CMD}

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
    echo "Python DUMMY job submission script reported success."
else
    echo "Error: Python DUMMY job submission script failed with exit code $JOB_SUBMIT_EXIT_CODE."
    # No need to exit 1 here, the trap will handle it and dump logs
    # exit 1
fi

echo "Script finished normally."
# Exit trap will run the cleanup function now.
