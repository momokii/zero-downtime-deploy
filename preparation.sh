#!/bin/bash

# ==============================================================================
# A preparation script for deployments.
# It checks network connectivity to essential services and pulls specified
# Docker images before the main deployment process begins.
#
# The script will exit immediately if any command fails.
# ==============================================================================

# --- Strict Mode ---
# 'set -e' will cause the script to exit immediately if a command exits with a
# non-zero status. This is crucial for our goal: stop on any failure.
set -e

# ===================================================
# ------------ Argument Validation Block ------------
# ===================================================

# Check if at least one argument (a Docker image name) is provided.
# "$#" holds the count of command-line arguments.
if [ "$#" -eq 0 ]; then
    echo "Error: No Docker images specified."
    echo "Usage: $0 <image1:tag> [<image2:tag> ...]"
    echo "Example: $0 my-registry/my-app:v2.1 nginx:latest redis:alpine"
    exit 1
fi

# Store all command-line arguments into an array named DOCKER_IMAGES.
# This is a best practice for handling a flexible number of inputs,
# especially those that might contain special characters.
DOCKER_IMAGES=("$@")

# ===================================================
# ---------- Connectivity Check Block -----------
# ===================================================

# --- Define essential URLs that must be accessible for the script to succeed ---
# You can add more URLs here, such as your private registry, artifact repository, etc.
REQUIRED_URLS=(
    "https://hub.docker.com"
    # "https://registry-1.docker.io" # example to add another url
)

echo "--- [Step 1/2] Checking network connectivity to required services ---"

# Loop through the array of URLs and test connectivity for each one.
for url in "${REQUIRED_URLS[@]}"; do
    echo "Pinging $url..."
    # Use curl to check if the service is reachable.
    # -s: Silent mode. Don't show progress meter or error messages.
    # -f: Fail silently. Return a non-zero exit code on server errors (HTTP >= 400).
    # --head: Fetch headers only. This is faster as it doesn't download the page body.
    # We redirect standard output to /dev/null as we only care about the exit code.
    if curl -sf --head "$url" > /dev/null; then
        echo "✅ Connection to $url is successful."
    else
        # This 'else' block provides a more user-friendly error message before exiting.
        # Even without it, 'set -e' would have stopped the script on curl's failure.
        echo "❌ Error: Could not connect to $url. Please check your network settings, DNS, or firewall rules."
        exit 1
    fi
done

echo "Network connectivity check passed."
echo # Add a blank line for better readability.

# ===================================================
# -------------- Docker Pull Block ----------------
# ===================================================

echo "--- [Step 2/2] Pulling specified Docker images ---"
echo "The script will stop immediately if any image fails to pull."
echo # Add a blank line.

# Loop through the provided Docker image names and pull them one by one.
# Because 'set -e' is active, this loop will automatically halt and the script
# will exit if any 'docker pull' command fails (e.g., image not found,
# invalid tag, or no permission).
for image in "${DOCKER_IMAGES[@]}"; do
    echo "Pulling image: $image..."
    docker pull "$image"
    echo "✅ Successfully pulled $image."
done

echo # Add a blank line.
echo "--------------------------------------------------"
echo "🎉 Preparation complete! All images were pulled successfully."
echo "--------------------------------------------------"