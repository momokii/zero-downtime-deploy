# Zero Downtime Deployment with Traefik

This repository provides a robust implementation of zero-downtime deployments using Traefik as a reverse proxy. The setup includes canary deployments, automatic health checks, and failsafe rollback mechanisms.

## Overview

The system implements a zero-downtime deployment strategy with the following key features:

- **Zero-Downtime Updates**: Seamless service updates without interrupting user traffic
- **Canary Deployments**: Gradual traffic shifting with automatic health monitoring
- **Automatic Rollback**: Failsafe mechanisms to prevent service disruption
- **Container-Based**: Fully containerized setup using Docker and Docker Compose
- **Traefik Integration**: Modern reverse proxy handling with dynamic configuration

## Project Structure

```
.
├── base-compose/          # Base Docker Compose template
│   └── compose.yaml
├── traefik/             # Traefik configuration files
│   ├── compose.yaml
│   ├── dynamic-config.yaml
│   └── traefik-config.yaml
├── update-proper.sh     # Main deployment script
├── update.sh     # base deployment script example without failsafe mechanism
├── init-deploy-example.sh # example script to start testing the update script
└── preparation.sh       # Environment preparation example script (for check the access for all data before usingg main update script)
```

## Getting Started

### Prerequisites

- Docker and Docker Compose installed
- Bash shell environment
- Basic understanding of container orchestration
- Traefik knowledge (basic)

### Initial Setup

1. Clone this repository
2. Run the preparation script:
   ```bash
   ./preparation.sh
   ```

### Configuration Files

#### Traefik Configuration
The setup uses two main Traefik configuration files:

- `traefik/traefik-config.yaml`: Static Traefik configuration
- `traefik/dynamic-config.yaml`: Dynamic routing and service configuration

## Deployment Process

### Basic Usage

The deployment script follows this syntax:
```bash
./update-proper.sh <service-name> <image-tag> <old-service-folder> <old-container-name> <port>
```

### Example Deployments

1. Updating from Nginx to Whoami service:
```bash
bash update-proper.sh main-app traefik/whoami:latest main-nginx main-nginx-container 80
```

2. Updating from Whoami back to Nginx:
```bash
bash update-proper.sh main-nginx nginx:latest main-app main-app-container 80
```

### Deployment Flow

1. **Pre-flight Validation**
   - Validates input parameters
   - Checks for existing containers
   - Verifies Docker image availability

2. **New Version Deployment**
   - Creates new service container
   - Performs initial health checks
   - Keeps old version running

3. **Canary Release**
   - Shifts 10% traffic to new version
   - Monitors application health
   - Validates under partial load

4. **Full Traffic Migration**
   - Gradually shifts 100% traffic to new version
   - Continues health monitoring
   - Maintains rollback capability

5. **Cleanup**
   - Removes old container
   - Cleans up temporary files
   - Updates configuration

## Failsafe Mechanisms

The system includes several failsafe features:

1. **Configuration Backups**
   - Automatic backup of Traefik configuration
   - Instant restoration on failure

2. **Health Monitoring**
   - Continuous health checks during deployment
   - Automatic failure detection

3. **Rollback Triggers**
   - Failed health checks
   - Service unavailability
   - Configuration errors

4. **Automatic Recovery**
   - Instant configuration restoration
   - Old service preservation until success
   - Clean failure state handling

## 🔍 Monitoring and Debugging

### Health Check Points

The system performs health checks at multiple stages:
- Initial deployment
- Canary phase (10% traffic)
- Full traffic migration
- Post-deployment verification

### Common Issues and Solutions

1. **Service Unavailability After Rollback**
   - Check Traefik logs for routing errors
   - Verify service name consistency
   - Ensure proper configuration restoration

2. **Failed Canary Deployment**
   - Monitor application logs
   - Check health check endpoints
   - Verify resource availability

## Best Practices

1. **Before Deployment**
   - Backup critical data
   - Verify image availability
   - Test new version in isolation

2. **During Deployment**
   - Monitor system metrics
   - Watch application logs
   - Keep track of deployment progress

3. **After Deployment**
   - Verify application functionality
   - Check for error logs
   - Monitor performance metrics

## Notes

- Always test deployments in a staging environment first
- Keep backup configurations readily available
- Monitor system resources during deployment
- Maintain consistent naming conventions
- Document any custom modifications

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.