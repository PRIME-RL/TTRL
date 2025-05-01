import time
import os
import logging

# Configure basic logging for the job
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s')

# Note: ray.init() is NOT called here. The job connects automatically.

logging.info(f"Dummy job starting on node {os.uname().nodename}")
logging.info("Dummy job implicitly connected to Ray cluster.")

# Optional: Add a check to see if Ray context is available
try:
    import ray
    if ray.is_initialized():
        logging.info(f"Ray cluster resources visible to job: {ray.cluster_resources()}")
    else:
        logging.warning("Ray context not automatically initialized in job?")
except ImportError:
    logging.warning("Ray library not found in job environment?")
except Exception as e:
    logging.error(f"Error checking Ray status in job: {e}")


logging.info("Dummy job sleeping for 20 seconds...")
time.sleep(20)
logging.info("Dummy job finished.")
