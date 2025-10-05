# Set variables for the initial deployment
export APP_IMAGE_TAG="nginx:alpine"
export APP_CONTAINER_NAME="main-nginx-container"
export APP_SERVICE_NAME="main-nginx-svc"
export NEW_BINDING_PORT=80

# create new folder base 
cp -r ./base-compose ./main-nginx

# Deploy the initial version
docker compose -f ./main-nginx/compose.yaml up -d

# Create the initial router config pointing to v1
# This file tells Traefik how to route traffic to your service
cat <<EOF > ./traefik/dynamic-config.yaml
http:
  routers:
    my-app-router:
      rule: "Host(\`localhost\`)" 
      service: "main-nginx-svc@docker"
      entryPoints:
        - web
EOF