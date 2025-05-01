import sys
import os
import time
import logging
from ray.job_submission import JobSubmissionClient, JobStatus

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s')

# Get Ray Dashboard address from environment variable
dashboard_address = os.environ.get("RAY_DASHBOARD_ADDRESS") # e.g., "http://1.2.3.4:8265"
working_dir = os.environ.get("RAY_JOB_WORKING_DIR", ".") # Get working dir from env

if not dashboard_address:
    logging.error("RAY_DASHBOARD_ADDRESS environment variable not set.")
    sys.exit(1)

# The actual command to run is passed as arguments to this script
entrypoint_command = " ".join(sys.argv[1:])
if not entrypoint_command:
    logging.error("No entrypoint command provided to submit_ray_job.py")
    sys.exit(1)

logging.info(f"Submitting job to Ray cluster at: {dashboard_address}")
logging.info(f"Working directory: {working_dir}")
logging.info(f"Entrypoint command: {entrypoint_command}")

try:
    client = JobSubmissionClient(dashboard_address)
    runtime_env = {"working_dir": working_dir}

    job_id = client.submit_job(
        entrypoint=entrypoint_command,
        runtime_env=runtime_env
    )
    logging.info(f"Successfully submitted job with ID: {job_id}")

    # --- Wait for job completion ---
    start_time = time.time()
    timeout_seconds = 3600 * 2 # Example: 2-hour timeout for waiting

    while time.time() - start_time < timeout_seconds:
        status = client.get_job_status(job_id)
        logging.info(f"Job '{job_id}' status: {status}")
        if status in {JobStatus.SUCCEEDED, JobStatus.STOPPED, JobStatus.FAILED}:
            break
        time.sleep(30) # Check status every 30 seconds
    else:
        logging.warning(f"Timeout waiting for job '{job_id}' to complete.")
        # Optionally stop the job if it timed out
        # client.stop_job(job_id)
        # sys.exit(1) # Exit with error on timeout

    # --- Get final status and logs ---
    final_status = client.get_job_status(job_id)
    logging.info(f"Job '{job_id}' final status: {final_status}")
    logging.info(f"--- Logs for job '{job_id}' ---")
    logs = client.get_job_logs(job_id)
    # Print line by line to avoid potential issues with huge log strings
    for line in logs.splitlines():
        print(line)
    logging.info(f"--- End logs for job '{job_id}' ---")

    if final_status == JobStatus.SUCCEEDED:
        logging.info("Job completed successfully.")
        sys.exit(0) # Exit with success code
    else:
        logging.error(f"Job failed or was stopped with status: {final_status}")
        sys.exit(1) # Exit with error code

except Exception as e:
    logging.exception(f"Failed to submit or monitor job: {e}")
    sys.exit(1)
