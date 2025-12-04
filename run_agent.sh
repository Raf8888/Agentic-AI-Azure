#!/bin/bash
# Simple script to load environment variables and run the agentic infrastructure agent
# Ensure this script and the .env file are in the same directory on the VM

# Load environment variables from .env file if present
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Run the agent script
python3 ~/agentic_infra_agent.py
