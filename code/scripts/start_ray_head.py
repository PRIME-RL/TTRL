import ray
import time
import os
import sys
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s')

# Get parameters from environment variables set by the Slurm script
node_ip_address = os.environ.get("HEAD_NODE_IP_ADDR")
dashboard_port = int(os.environ.get("RAY_DASHBOARD_PORT", 8265))
num_gpus = int(os.environ.get("SLURM_GPUS_ON_NODE", 0)) # Default to 0 if not set

if not node_ip_address:
    logging.error("HEAD_NODE_IP_ADDR environment variable not set.")
    sys.exit(1)

logging.info(f"Attempting to start Ray head node...")
logging.info(f"  Node IP Address: {node_ip_address}")
logging.info(f"  Dashboard Port: {dashboard_port}")
logging.info(f"  Num GPUs: {num_gpus}")

try:
    # Start Ray head node programmatically
    # Remove address='auto' to force starting a new instance
    ray.init(
        # address='auto', # REMOVE THIS LINE
        _node_ip_address=node_ip_address,
        dashboard_host='0.0.0.0',
        dashboard_port=dashboard_port,
        num_gpus=num_gpus,
        include_dashboard=True, # Enable dashboard for ray job submit
        logging_level=logging.INFO, # Or logging.DEBUG for more verbosity
        # Add other relevant configurations if needed
        # e.g., object_store_memory, _temp_dir, etc.
    )
    logging.info("Ray head node started successfully via ray.init().")
    logging.info(f"Dashboard running at http://{node_ip_address}:{dashboard_port}")

    # Keep the script running to keep the Ray head alive
    while True:
        time.sleep(60) # Keep alive, sleep for a minute

except Exception as e:
    logging.exception(f"Failed to start Ray head node: {e}")
    sys.exit(1)

finally:
    # This part might not be reached if terminated externally,
    # but good practice to include shutdown.
    if ray.is_initialized():
        logging.info("Shutting down Ray...")
        ray.shutdown()
    logging.info("Python script exiting.")
