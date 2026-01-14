#!/bin/bash

##############################################################################
# Script to easily run IBM CICS TG 10.1 Container from Red Hat Registry
# Uses: images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1
##############################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
CICS_IMAGE="images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1"
CONTAINER_NAME="cics-ctg-container"
CTG_PORT=2006
CTG_SSL_PORT=2035

show_usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    pull            Pull the CICS TG image from Red Hat registry
    run             Run the CICS TG container
    stop            Stop the container
    restart         Restart the container
    logs            Show container logs
    shell           Open shell in container
    status          Check container status
    clean           Remove container (keeps image)
    clean-all       Remove container and image

Options:
    --port PORT     Override default CTG port (default: 2006)

Examples:
    # First time setup
    $0 pull
    $0 run

    # Day-to-day usage
    $0 run          # Start container
    $0 logs         # View logs
    $0 stop         # Stop container
    $0 status       # Check status

Image: ${CICS_IMAGE}

EOF
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        exit 1
    fi
}

pull_image() {
    print_step "Pulling CICS TG image from Red Hat registry..."
    print_info "Image: $CICS_IMAGE"

    docker pull $CICS_IMAGE

    if [ $? -eq 0 ]; then
        print_info "Image pulled successfully"
        docker images | grep ibm-cicstg-container || true
    else
        print_error "Failed to pull image"
        print_info "Make sure you have access to the Red Hat registry"
        exit 1
    fi
}

run_container() {
    print_step "Running CICS TG container..."

    # Check if image exists
    if ! docker images | grep -q "ibm-cicstg-container"; then
        print_warn "CICS TG image not found locally"
        print_info "Pulling image first..."
        pull_image
    fi

    # Check if container already exists
    if docker ps -a | grep -q $CONTAINER_NAME; then
        print_warn "Container $CONTAINER_NAME already exists"
        print_info "Stopping and removing existing container..."
        docker stop $CONTAINER_NAME 2>/dev/null || true
        docker rm $CONTAINER_NAME 2>/dev/null || true
    fi

    # Create directories for volumes
    mkdir -p config logs data

    print_info "Starting container with LICENSE=accept..."
    docker run -d \
        --name $CONTAINER_NAME \
        -e LICENSE=accept \
        -p ${CTG_PORT}:2006 \
        -p ${CTG_SSL_PORT}:2035 \
        -v $(pwd)/config:/opt/ibm/ctg/config \
        -v $(pwd)/logs:/opt/ibm/ctg/logs \
        -v $(pwd)/data:/opt/ibm/ctg/data \
        $CICS_IMAGE

    print_info "Container started successfully!"
    print_info "Container name: $CONTAINER_NAME"
    print_info "CTG Port: $CTG_PORT"
    print_info "CTG SSL Port: $CTG_SSL_PORT"
    echo ""

    # Copy custom config file to the correct location
    if [ -f "config/ctg.ini" ]; then
        print_info "Copying custom config file to container..."
        docker cp config/ctg.ini $CONTAINER_NAME:/var/cicscli/ctg.ini
        print_info "Restarting container to apply configuration..."
        docker restart $CONTAINER_NAME > /dev/null
        sleep 3
    fi

    print_info "Waiting for CTG to start (this may take 30-60 seconds)..."
    sleep 5

    # Show initial logs
    docker logs $CONTAINER_NAME

    echo ""
    print_info "View logs with: $0 logs"
    print_info "Check status with: $0 status"
}

stop_container() {
    print_step "Stopping CICS TG container..."
    if docker ps | grep -q $CONTAINER_NAME; then
        docker stop $CONTAINER_NAME
        print_info "Container stopped"
    else
        print_warn "Container is not running"
    fi
}

restart_container() {
    print_step "Restarting CICS TG container..."
    docker restart $CONTAINER_NAME
    print_info "Container restarted"
    sleep 3
    docker logs --tail 20 $CONTAINER_NAME
}

show_logs() {
    print_info "Showing container logs (Ctrl+C to exit)..."
    docker logs -f $CONTAINER_NAME
}

open_shell() {
    print_step "Opening shell in container..."
    docker exec -it $CONTAINER_NAME /bin/bash
}

show_status() {
    print_step "Container status:"
    echo ""

    if docker ps | grep -q $CONTAINER_NAME; then
        print_info "Container is running"
        docker ps | grep $CONTAINER_NAME
    elif docker ps -a | grep -q $CONTAINER_NAME; then
        print_warn "Container exists but is not running"
        docker ps -a | grep $CONTAINER_NAME
    else
        print_warn "Container not found"
        echo ""
        echo "Run: $0 run"
        return
    fi

    echo ""
    print_step "CTG port status:"
    if docker exec $CONTAINER_NAME netstat -an 2>/dev/null | grep -q 2006; then
        print_info "CTG is listening on port 2006"
        docker exec $CONTAINER_NAME netstat -an | grep 2006
    else
        print_warn "CTG not listening on port 2006 yet (may still be starting)"
    fi

    echo ""
    print_step "Container health:"
    docker inspect --format='{{.State.Health.Status}}' $CONTAINER_NAME 2>/dev/null || print_warn "Health check not available"

    echo ""
    print_step "Container IP:"
    docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME 2>/dev/null || print_warn "IP not available"
}

clean_container() {
    print_step "Removing container (keeping image)..."
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
    print_info "Container removed"
}

clean_all() {
    print_warn "This will remove the container AND the image"
    print_warn "You'll need to pull the image again (docker pull)"
    echo -n "Continue? (y/N): "
    read -r response

    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        print_step "Removing container..."
        docker stop $CONTAINER_NAME 2>/dev/null || true
        docker rm $CONTAINER_NAME 2>/dev/null || true

        print_step "Removing image..."
        docker rmi $CICS_IMAGE 2>/dev/null || true

        print_info "Cleanup complete"
    else
        print_info "Cancelled"
    fi
}

# Parse arguments
check_docker

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            CTG_PORT="$2"
            shift 2
            ;;
        pull|run|stop|restart|logs|shell|status|clean|clean-all)
            COMMAND="$1"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Execute command
case "${COMMAND:-}" in
    pull)
        pull_image
        ;;
    run)
        run_container
        ;;
    stop)
        stop_container
        ;;
    restart)
        restart_container
        ;;
    logs)
        show_logs
        ;;
    shell)
        open_shell
        ;;
    status)
        show_status
        ;;
    clean)
        clean_container
        ;;
    clean-all)
        clean_all
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
