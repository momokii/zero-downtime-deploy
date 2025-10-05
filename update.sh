#!/bin/bash

# ===================================================
# ------------ Argument Validation Block ------------
# ===================================================
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <new-service-folder-name> <new-image-tag> <old-service-folder-name> <old-container-name> <new-binding-port>"
    echo "Example: $0 my-app my-registry/my-app:v2.1 my-app-old my-app-v1 8001"
    exit 1
fi

SERVICE_NAME="$1"
NEW_IMAGE_TAG="$2"
OLD_SERVICE_FOLDER="$3"
OLD_CONTAINER_NAME="$4"
NEW_BINDING_PORT="$5"

# --- Check if old folder and old container are valid ---

# Check if the old service folder exists. The '-d' flag checks for a directory.
if [ ! -d "$OLD_SERVICE_FOLDER" ]; then
    echo "Error: Old service folder '$OLD_SERVICE_FOLDER' not found."
    exit 1
fi

# Check if the old Docker container is currently running.
# We use 'docker ps' with a quiet flag '-q' and a filter for an exact name match.
# If the command returns an empty string, the container does not exist or is not running.
# The '^' and '$' ensure an exact match for the container name.
if [ -z "$(docker ps -q --filter "name=^${OLD_CONTAINER_NAME}$")" ]; then
    echo "Error: Old container '$OLD_CONTAINER_NAME' is not running or does not exist."
    exit 1
fi

echo "Validation successful. Old folder and container found."
echo "Proceeding with deployment..."

# check if the new service name is the same like the older, make it not possible
if [ "$SERVICE_NAME" == "$OLD_CONTAINER_NAME" ]; then
    echo "Error: New service name ('$SERVICE_NAME') cannot be the same as the old container name ('$OLD_CONTAINER_NAME')."
    exit 1
fi

# Check if the new Docker image to be deployed exists locally.
# We use 'docker images -q' which returns the image ID if it exists, or an empty string otherwise.
if [ -z "$(docker images -q "$NEW_IMAGE_TAG")" ]; then
    echo "Error: The new image '$NEW_IMAGE_TAG' was not found locally."
    echo "For a seamless process, please ensure the new Docker image is available before running this script."
    exit 1
fi

echo "✅ Arguments validated successfully."

# ===================================================
# -------------- MAIN DEPLOYMENT BLOCK --------------
# ===================================================

# create new folder for the new update version docker, we use the base folder setup
if cp -r ./base-compose ./${SERVICE_NAME}; then
    echo "Create new base folder success"
else
    echo "Create new folder failed, exit..."
    exit 1
fi

# --- Define Variables ---
APP_COMPOSE_FILE="./${SERVICE_NAME}/compose.yaml"
DYNAMIC_CONFIG_PATH="./traefik/dynamic-config.yaml"
NEW_CONTAINER_NAME="${SERVICE_NAME}"
OLD_TRAEFIK_SERVICE="${OLD_CONTAINER_NAME}-svc@docker"
NEW_TRAEFIK_SERVICE="${NEW_CONTAINER_NAME}-svc@docker"

# --- STEP 1: Deploy the New Version in the Background ---
echo "▶️  Deploying new version (${NEW_CONTAINER_NAME}) without exposing to traffic..."
export APP_IMAGE_TAG=${NEW_IMAGE_TAG}
export APP_CONTAINER_NAME=${NEW_CONTAINER_NAME}
export APP_SERVICE_NAME="${NEW_CONTAINER_NAME}-svc"
export NEW_BINDING_PORT=${NEW_BINDING_PORT}
docker compose -f ${APP_COMPOSE_FILE} up -d

# --- STEP 2: Validate the New Container ---
echo "🔎 Validating the new container before shifting traffic..."
VALIDATED=false
for i in {1..30}; do
    CONTAINER_IP=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" ${NEW_CONTAINER_NAME})
    if [ -n "$CONTAINER_IP" ] && curl -s --fail "http://${CONTAINER_IP}"; then
        echo "✅ Validation successful! Container ${NEW_CONTAINER_NAME} is healthy."
        VALIDATED=true
        break
    fi
    echo "  - Waiting for container to be healthy... attempt $i"
    sleep 2
done

if [ "$VALIDATED" != true ]; then
    echo "❌ Validation failed for ${NEW_CONTAINER_NAME}. Aborting deployment."
    docker rm -f ${NEW_CONTAINER_NAME}
    exit 1
fi

# --- STEP 3: Canary Release (Shift a small portion of traffic) ---
echo "🐦 Performing Canary Release: 90% traffic to old version, 10% to new version..."
cat <<EOF > ${DYNAMIC_CONFIG_PATH}
http:
  routers:
    ${SERVICE_NAME}-router:
      rule: "Host(\`localhost\`)"
      service: ${SERVICE_NAME}-weighted-svc
      entryPoints:
        - web
  services:
    ${SERVICE_NAME}-weighted-svc:
      weighted:
        services:
          - name: ${OLD_TRAEFIK_SERVICE}
            weight: 9
          - name: ${NEW_TRAEFIK_SERVICE}
            weight: 1
EOF

echo "⏳ Monitoring phase... (simulating a 30-second wait)"
sleep 30

# --- STEP 4: Shift 100% Traffic to the New Version ---
echo "🏆 Shifting 100% of traffic to the new version..."
cat <<EOF > ${DYNAMIC_CONFIG_PATH}
http:
  routers:
    ${SERVICE_NAME}-router:
      rule: "Host(\`localhost\`)"
      service: ${NEW_TRAEFIK_SERVICE}
      entryPoints:
        - web
EOF

echo "⏳ Allowing time for connections to transition... (5 seconds)"
sleep 5

# --- STEP 5: Tear Down the Old Version (REVISED AND CORRECTED) ---
echo "⛔ Decommissioning the old container (${OLD_CONTAINER_NAME})..."

# Directly and explicitly remove the old container by its unique name.
# The '-f' flag forces the removal even if it is running.
# This is much safer and more reliable than using 'docker-compose down'.
if docker ps -q -f "name=^${OLD_CONTAINER_NAME}$" | grep -q .; then
    docker rm -f ${OLD_CONTAINER_NAME}
    echo "  - Successfully removed container: ${OLD_CONTAINER_NAME}"

    # after remove container, remove the folder for make the setup clean
    echo "  - Delete old folder setup..."
    rm -rf ./${OLD_SERVICE_FOLDER}
    echo "  - Delete old folder success" 
else
    echo "  - Container ${OLD_CONTAINER_NAME} not found or already removed. Skipping."
fi

echo "🎉 Deployment successful for ${SERVICE_NAME} with image ${NEW_IMAGE_TAG}!"