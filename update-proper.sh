#!/bin/bash

# ===================================================
#      Zero-Downtime Canary Deployment Script
#     with Failsafe and Rollback Mechanisms
# ===================================================

# --- Script Configuration ---
# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Pipelines fail if any command fails, not just the last one.
set -euo pipefail

# --- Global Variables ---
# We use a temporary file to store the name of the new container.
# This helps the trap/rollback function know what to clean up.
NEW_CONTAINER_NAME_TEMP_FILE=$(mktemp)
DYNAMIC_CONFIG_PATH="./traefik/dynamic-config.yaml"
DYNAMIC_CONFIG_BACKUP_PATH="${DYNAMIC_CONFIG_PATH}.bak"
ROUTER_NAME=my-app-router

CURRENT_ROUTER_NAME=$(yq eval '.http.routers | keys | .[0]' "$DYNAMIC_CONFIG_PATH" || echo "main-app-router")
ROUTER_NAME="${CURRENT_ROUTER_NAME}"

# ===================================================
# ------------ Failsafe/Rollback Block --------------
# ===================================================

# This function is the core of our failsafe strategy.
# It's called by the 'trap' command on any script error or exit.
function rollback_and_cleanup() {
    echo "⚠️ An error occurred. Initiating rollback and cleanup..."

    # Restore Traefik config from backup if the backup exists.
    if [ -f "$DYNAMIC_CONFIG_BACKUP_PATH" ]; then
        echo "  - Restoring Traefik dynamic configuration from backup..."
        cp "$DYNAMIC_CONFIG_BACKUP_PATH" "$DYNAMIC_CONFIG_PATH"  # Changed from mv to cp
        
        # Verify the config was restored correctly
        if ! diff "$DYNAMIC_CONFIG_BACKUP_PATH" "$DYNAMIC_CONFIG_PATH" >/dev/null; then
            echo "⚠️ Warning: Config restoration may have failed"
        fi
        
        # Give Traefik a moment to reload the old configuration
        echo "  - Waiting for Traefik to reload old configuration..."
        sleep 5  # Increased from 3 to 5 seconds
        
        # Verify the old service is responding
        if ! curl -s --fail "http://localhost" >/dev/null 2>&1; then
            echo "⚠️ Warning: Original service is not responding after rollback"
        fi
    fi

    # Remove the new container if it was created.
    if [ -s "$NEW_CONTAINER_NAME_TEMP_FILE" ]; then
        local new_container_name
        new_container_name=$(cat "$NEW_CONTAINER_NAME_TEMP_FILE")
        if [ -n "$new_container_name" ] && [ -n "$(docker ps -q -f "name=^${new_container_name}$")" ]; then
            echo "  - Removing new container '${new_container_name}'..."
            docker rm -f "$new_container_name"
        fi
    fi

    if [ -d "./${SERVICE_NAME}" ]; then
        echo "  - Removing new service folder './${SERVICE_NAME}'..."
        rm -rf "./${SERVICE_NAME}"
    fi

    rm -f "$NEW_CONTAINER_NAME_TEMP_FILE"
    rm -f "$DYNAMIC_CONFIG_BACKUP_PATH"

    echo "✅ Rollback complete. System restored to its previous state."
}

# The 'trap' command registers the 'rollback_and_cleanup' function to be
# executed whenever the script exits, whether due to an error (ERR)
# or normal completion (EXIT). This is our safety net.
trap rollback_and_cleanup EXIT ERR

# ===================================================
# ------------ Argument Validation Block ------------
# ===================================================

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <new-service-folder-name> <new-image-tag> <old-service-folder-name> <old-container-name> <new-binding-port>"
    echo "Example: $0 my-app-v2 my-registry/my-app:v2.1 my-app-v1 my-app-v1-container 8001"
    exit 1
fi

# --- Assign Arguments to Variables ---
SERVICE_NAME="$1"
NEW_IMAGE_TAG="$2"
OLD_SERVICE_FOLDER="$3"
OLD_CONTAINER_NAME="$4"
NEW_BINDING_PORT="$5"
NEW_CONTAINER_NAME="${SERVICE_NAME}-container" # More explicit container naming

# --- Pre-flight Checks ---
echo "🔎 Performing pre-flight validation..."

if [ ! -d "$OLD_SERVICE_FOLDER" ]; then
    echo "Error: Old service folder '$OLD_SERVICE_FOLDER' not found."
    exit 1
fi

if [ -z "$(docker ps -q --filter "name=^${OLD_CONTAINER_NAME}$")" ]; then
    echo "Error: Old container '$OLD_CONTAINER_NAME' is not running or does not exist."
    exit 1
fi

if [ "$NEW_CONTAINER_NAME" == "$OLD_CONTAINER_NAME" ]; then
    echo "Error: New container name ('$NEW_CONTAINER_NAME') cannot be the same as the old one ('$OLD_CONTAINER_NAME')."
    exit 1
fi

if [ -z "$(docker images -q "$NEW_IMAGE_TAG")" ]; then
    echo "Error: The new image '$NEW_IMAGE_TAG' was not found locally. Please pull it first."
    exit 1
fi

echo "✅ Pre-flight validation successful."

# ===================================================
# -------------- MAIN DEPLOYMENT BLOCK --------------
# ===================================================

# --- STEP 1: Deploy the New Version (Isolated) ---
echo "▶️  Deploying new version (${NEW_CONTAINER_NAME}) without exposing it to traffic..."

if ! cp -r ./base-compose "./${SERVICE_NAME}"; then
    echo "Error: Failed to create new service folder."
    exit 1
fi

# Store the new container name in the temp file for the trap handler.
echo -n "${NEW_CONTAINER_NAME}" > "$NEW_CONTAINER_NAME_TEMP_FILE"

APP_COMPOSE_FILE="./${SERVICE_NAME}/compose.yaml"

# Export variables for docker-compose
export APP_IMAGE_TAG=${NEW_IMAGE_TAG}
export APP_CONTAINER_NAME=${NEW_CONTAINER_NAME}
export APP_SERVICE_NAME="${SERVICE_NAME}-svc"
export NEW_BINDING_PORT=${NEW_BINDING_PORT}

docker compose -f "${APP_COMPOSE_FILE}" up -d

# --- STEP 2: Initial Health Check (Isolated) ---
echo "🔎 Performing initial health check on the new container..."
VALIDATED=false
for i in {1..15}; do
    # Check health via internal Docker IP before exposing to Traefik
    CONTAINER_IP=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "${NEW_CONTAINER_NAME}")
    if [ -n "$CONTAINER_IP" ] && curl -s --fail "http://${CONTAINER_IP}"; then
        echo "✅ Initial health check passed! Container ${NEW_CONTAINER_NAME} is healthy."
        VALIDATED=true
        break
    fi
    echo "  - Waiting for container to be healthy... attempt $i"
    sleep 2
done

if [ "$VALIDATED" != true ]; then
    echo "❌ Initial health check failed for ${NEW_CONTAINER_NAME}. Aborting deployment."
    # The trap will handle the cleanup.
    exit 1
fi

# --- STEP 3: Canary Release (Shift Partial Traffic) & VALIDATE UNDER LOAD ---
echo "🐦 Performing Canary Release: Shifting 10% traffic to the new version..."

# FAILSAFE: Backup the current Traefik configuration before modifying it.
cp "$DYNAMIC_CONFIG_PATH" "$DYNAMIC_CONFIG_BACKUP_PATH"

OLD_TRAEFIK_SERVICE="${OLD_SERVICE_FOLDER}-svc@docker"
NEW_TRAEFIK_SERVICE="${APP_SERVICE_NAME}@docker"

cat <<EOF > "${DYNAMIC_CONFIG_PATH}"
http:
  routers:
    ${ROUTER_NAME}:
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

echo "⏳ Monitoring canary health for 30 seconds..."
CANARY_HEALTHY=false
for i in {1..10}; do
    # We check the public-facing endpoint now.
    if curl -s --fail "http://localhost"; then
        echo "  - Canary check $i/10 passed."
        CANARY_HEALTHY=true
        sleep 3
    else
        echo "  - ❌ Canary check $i/10 failed!"
        CANARY_HEALTHY=false
        break
    fi
done

if [ "$CANARY_HEALTHY" != true ]; then
    echo "❌ Canary deployment failed health checks under traffic. Aborting."
    # The trap will restore the backup config and remove the new container.
    exit 1
fi
echo "✅ Canary deployment is stable."


# --- STEP 4: Shift 100% Traffic to New Version ---
echo "🏆 Shifting 100% of traffic to the new version..."
cat <<EOF > "${DYNAMIC_CONFIG_PATH}"
http:
  routers:
    ${ROUTER_NAME}:
      rule: "Host(\`localhost\`)"
      service: ${NEW_TRAEFIK_SERVICE}
      entryPoints:
        - web
EOF

echo "⏳ Allowing time for connections to transition... (5 seconds)"
sleep 5

# A final, quick health check after full traffic shift
if ! curl -s --fail "http://localhost"; then
    echo "❌ Final health check failed after shifting 100% traffic. Aborting."
    # The trap will restore the config from the canary phase, effectively rolling back.
    exit 1
fi
echo "✅ New version is stable with 100% traffic."


# --- STEP 5: Decommission Old Version ---
echo "⛔ Decommissioning the old container (${OLD_CONTAINER_NAME})..."
docker rm -f "${OLD_CONTAINER_NAME}"
echo "  - Successfully removed container: ${OLD_CONTAINER_NAME}"

echo "  - Removing old service folder: ${OLD_SERVICE_FOLDER}..."
rm -rf "./${OLD_SERVICE_FOLDER}"
echo "  - Successfully removed old service folder."


# --- Finalization ---
# If we reach this point, the deployment was successful.
# We no longer need the trap to perform a rollback, so we clear it.
# We also remove the backup and temp files.
trap - EXIT ERR
rm -f "$DYNAMIC_CONFIG_BACKUP_PATH"
rm -f "$NEW_CONTAINER_NAME_TEMP_FILE"

echo "🎉 Deployment successful for ${SERVICE_NAME} with image ${NEW_IMAGE_TAG}!"