#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to confirm cleanup
confirm_cleanup() {
    echo -e "${YELLOW}WARNING: This will remove all containers, volumes, networks, and images related to the Kafka project.${NC}"
    echo "The following will be cleaned up:"
    echo "  • All Docker containers (Kafka clusters, MirrorMaker 2, producers, etc.)"
    echo "  • All Docker volumes (persistent data will be lost)"
    echo "  • Docker networks created by the project"
    echo "  • Custom Docker images (enhanced-mirrormaker2, commit-log-producer)"
    echo

    if [ "${FORCE_CLEANUP:-}" = "true" ]; then
        print_status "Force cleanup mode enabled, skipping confirmation..."
        return 0
    fi

    read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Cleanup cancelled."
        exit 0
    fi
}

# Function to stop and remove containers
cleanup_containers() {
    print_status "Stopping and removing Docker containers..."

    # Stop all containers using docker-compose
    if [ -f "docker-compose.yml" ]; then
        docker-compose down --remove-orphans 2>/dev/null || true
        print_success "Docker Compose containers stopped and removed"
    fi

    # Find and remove any remaining containers related to this project
    local containers=$(docker ps -aq --filter "name=kafka-project" 2>/dev/null || true)
    if [ -n "$containers" ]; then
        print_status "Removing remaining project containers..."
        docker rm -f $containers 2>/dev/null || true
    fi

    # Remove any other containers that might be related
    local other_containers=$(docker ps -aq --filter "label=com.docker.compose.project=kafka-project" 2>/dev/null || true)
    if [ -n "$other_containers" ]; then
        print_status "Removing labeled project containers..."
        docker rm -f $other_containers 2>/dev/null || true
    fi
}

# Function to remove volumes
cleanup_volumes() {
    print_status "Removing Docker volumes..."

    # Remove volumes created by docker-compose
    if [ -f "docker-compose.yml" ]; then
        docker-compose down -v 2>/dev/null || true
    fi

    # Find and remove project-specific volumes
    local volumes=$(docker volume ls -q --filter "name=kafka-project" 2>/dev/null || true)
    if [ -n "$volumes" ]; then
        print_status "Removing project volumes: $volumes"
        echo "$volumes" | xargs docker volume rm 2>/dev/null || true
    fi

    # Remove other commonly named volumes
    local common_volumes=(
        "local-development_primary-kafka-data"
        "local-development_standby-kafka-data"
        "primary-kafka-data"
        "standby-kafka-data"
    )

    for volume in "${common_volumes[@]}"; do
        if docker volume ls | grep -q "$volume"; then
            print_status "Removing volume: $volume"
            docker volume rm "$volume" 2>/dev/null || true
        fi
    done

    print_success "Volume cleanup completed"
}

# Function to remove networks
cleanup_networks() {
    print_status "Removing Docker networks..."

    # Remove networks created by docker-compose
    local networks=$(docker network ls --filter "name=kafka-project" -q 2>/dev/null || true)
    if [ -n "$networks" ]; then
        print_status "Removing project networks..."
        echo "$networks" | xargs docker network rm 2>/dev/null || true
    fi

    # Remove common network names
    local common_networks=(
        "local-development_kafka-network"
        "kafka-network"
    )

    for network in "${common_networks[@]}"; do
        if docker network ls | grep -q "$network"; then
            print_status "Removing network: $network"
            docker network rm "$network" 2>/dev/null || true
        fi
    done

    print_success "Network cleanup completed"
}

# Function to remove custom images
cleanup_images() {
    print_status "Removing custom Docker images..."

    local custom_images=(
        "enhanced-mirrormaker2:latest"
        "commit-log-producer:latest"
    )

    for image in "${custom_images[@]}"; do
        if docker images | grep -q "$(echo $image | cut -d: -f1)"; then
            print_status "Removing image: $image"
            docker rmi "$image" 2>/dev/null || true
        fi
    done

    # Remove dangling images
    local dangling=$(docker images -f "dangling=true" -q 2>/dev/null || true)
    if [ -n "$dangling" ]; then
        print_status "Removing dangling images..."
        echo "$dangling" | xargs docker rmi 2>/dev/null || true
    fi

    print_success "Image cleanup completed"
}

# Function to clean up temporary files
cleanup_temp_files() {
    print_status "Cleaning up temporary files..."

    # Remove any temporary directories or files created during the project
    local temp_dirs=(
        "temp_docx"
        ".tmp"
        "tmp"
    )

    for dir in "${temp_dirs[@]}"; do
        if [ -d "$dir" ]; then
            print_status "Removing temporary directory: $dir"
            rm -rf "$dir"
        fi
    done

    print_success "Temporary file cleanup completed"
}

# Function to show system status after cleanup
show_status() {
    print_status "=== CLEANUP STATUS ==="

    echo -e "\n${BLUE}Remaining containers:${NC}"
    local remaining_containers=$(docker ps -a --filter "name=kafka" 2>/dev/null | wc -l)
    echo "Kafka-related containers: $((remaining_containers - 1))"

    echo -e "\n${BLUE}Remaining volumes:${NC}"
    local remaining_volumes=$(docker volume ls --filter "name=kafka" 2>/dev/null | wc -l)
    echo "Kafka-related volumes: $((remaining_volumes - 1))"

    echo -e "\n${BLUE}Remaining networks:${NC}"
    local remaining_networks=$(docker network ls --filter "name=kafka" 2>/dev/null | wc -l)
    echo "Kafka-related networks: $((remaining_networks - 1))"

    echo -e "\n${BLUE}Custom images:${NC}"
    docker images | grep -E "(enhanced-mirrormaker2|commit-log-producer)" || echo "No custom images found"

    echo -e "\n${BLUE}Docker system disk usage:${NC}"
    docker system df 2>/dev/null || echo "Unable to get disk usage"
}

# Function to perform system prune (optional)
system_prune() {
    if [ "${SYSTEM_PRUNE:-}" = "true" ]; then
        print_status "Performing Docker system prune..."
        docker system prune -f 2>/dev/null || true
        print_success "System prune completed"
    else
        echo
        print_status "Optional: Run 'docker system prune' to clean up additional unused Docker resources"
    fi
}

# Main cleanup function
main() {
    print_status "Starting infrastructure cleanup..."

    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running. Cannot perform cleanup."
        exit 1
    fi

    # Confirm cleanup
    confirm_cleanup

    # Perform cleanup steps
    cleanup_containers
    cleanup_volumes
    cleanup_networks
    cleanup_images
    cleanup_temp_files

    # Show status
    show_status

    # Optional system prune
    system_prune

    print_success "Infrastructure cleanup completed!"
    print_status "All project-related Docker resources have been removed."
}

# Script options
case "${1:-}" in
    "containers")
        print_status "Cleaning up containers only..."
        cleanup_containers
        ;;
    "volumes")
        print_status "Cleaning up volumes only..."
        cleanup_volumes
        ;;
    "networks")
        print_status "Cleaning up networks only..."
        cleanup_networks
        ;;
    "images")
        print_status "Cleaning up images only..."
        cleanup_images
        ;;
    "status")
        show_status
        ;;
    "force")
        FORCE_CLEANUP=true
        main
        ;;
    "prune")
        FORCE_CLEANUP=true
        SYSTEM_PRUNE=true
        main
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo "Commands:"
        echo "  (no args)  - Full cleanup with confirmation"
        echo "  containers - Clean up containers only"
        echo "  volumes    - Clean up volumes only"
        echo "  networks   - Clean up networks only"
        echo "  images     - Clean up images only"
        echo "  status     - Show current status"
        echo "  force      - Full cleanup without confirmation"
        echo "  prune      - Full cleanup + Docker system prune"
        echo "  help       - Show this help"
        echo
        echo "Environment variables:"
        echo "  FORCE_CLEANUP=true   - Skip confirmation prompts"
        echo "  SYSTEM_PRUNE=true    - Run docker system prune after cleanup"
        ;;
    *)
        main
        ;;
esac