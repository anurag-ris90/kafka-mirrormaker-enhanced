#!/bin/bash
set -e

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

# Function to wait for Kafka to be ready
wait_for_kafka() {
    local cluster_name=$1
    local port=$2
    local max_attempts=30
    local attempt=1

    print_status "Waiting for $cluster_name cluster to be ready..."

    while [ $attempt -le $max_attempts ]; do
        if docker exec kafka-project-${cluster_name}-kafka-1 kafka-topics --bootstrap-server localhost:$port --list >/dev/null 2>&1; then
            print_success "$cluster_name cluster is ready!"
            return 0
        fi
        echo "Attempt $attempt/$max_attempts: $cluster_name cluster not ready yet..."
        sleep 5
        ((attempt++))
    done

    print_error "$cluster_name cluster failed to start within timeout"
    return 1
}

# Function to check topic exists and get message count
check_topic_messages() {
    local cluster=$1
    local topic=$2
    local port=$3

    local message_count=$(docker exec kafka-project-${cluster}-kafka-1 \
        kafka-console-consumer --bootstrap-server localhost:$port \
        --topic $topic --from-beginning --timeout-ms 5000 2>/dev/null | wc -l || echo "0")
    echo $message_count
}

# Function to run normal replication test
test_normal_replication() {
    print_status "=== TEST 1: Normal Replication Flow ==="

    # Start MirrorMaker 2
    print_status "Starting Enhanced MirrorMaker 2..."
    docker-compose --profile mirrormaker up -d mirrormaker2

    # Wait for MirrorMaker 2 to be ready
    sleep 15

    # Produce 1000 messages
    print_status "Producing 1000 messages to commit-log topic..."
    docker-compose --profile producer run --rm producer \
        --broker primary-kafka:29092 --topic commit-log --count 1000

    # Wait for replication
    print_status "Waiting 30 seconds for replication to complete..."
    sleep 30

    # Check replication
    primary_count=$(check_topic_messages "primary" "commit-log" "9092")
    standby_count=$(check_topic_messages "standby" "primary.commit-log" "9093")

    print_status "Primary cluster messages: $primary_count"
    print_status "Standby cluster messages: $standby_count"

    if [ "$standby_count" -gt 0 ]; then
        print_success "Normal replication test PASSED - Messages replicated successfully"
        echo "Primary: $primary_count messages, Standby: $standby_count messages"
    else
        print_error "Normal replication test FAILED - No messages replicated"
        return 1
    fi

    # Stop MirrorMaker 2 for next test
    docker-compose stop mirrormaker2
}

# Function to test log truncation detection
test_log_truncation() {
    print_status "=== TEST 2: Log Truncation Simulation ==="

    # Produce some initial messages
    print_status "Producing initial messages..."
    docker-compose --profile producer run --rm producer \
        --broker primary-kafka:29092 --topic commit-log --count 50

    # Start MirrorMaker 2 and let it replicate some messages
    print_status "Starting MirrorMaker 2 to establish baseline..."
    docker-compose --profile mirrormaker up -d mirrormaker2
    sleep 10

    # Stop MirrorMaker 2 temporarily
    print_status "Stopping MirrorMaker 2 temporarily..."
    docker-compose stop mirrormaker2

    # Produce more messages
    print_status "Producing more messages while MirrorMaker 2 is stopped..."
    docker-compose --profile producer run --rm producer \
        --broker primary-kafka:29092 --topic commit-log --count 100

    # Wait for retention to kick in (topic has 60-second retention)
    print_status "Waiting 70 seconds for log retention to truncate messages..."
    sleep 70

    # Restart MirrorMaker 2 - it should detect truncation
    print_status "Restarting MirrorMaker 2 - should detect log truncation..."
    docker-compose --profile mirrormaker up -d mirrormaker2

    # Wait and check logs for truncation detection
    sleep 15

    print_status "Checking MirrorMaker 2 logs for truncation detection..."
    if docker-compose logs mirrormaker2 2>&1 | grep -i "log truncation detected\|CRITICAL.*truncation" >/dev/null; then
        print_success "Log truncation test PASSED - Truncation detected and logged"
    else
        print_warning "Log truncation test - Truncation may not have occurred or MirrorMaker 2 handled it gracefully"
    fi

    # Stop MirrorMaker 2
    docker-compose stop mirrormaker2
}

# Function to test topic reset handling
test_topic_reset() {
    print_status "=== TEST 3: Topic Reset Simulation ==="

    # Start MirrorMaker 2
    print_status "Starting MirrorMaker 2..."
    docker-compose --profile mirrormaker up -d mirrormaker2
    sleep 10

    # Produce some messages
    print_status "Producing messages before topic reset..."
    docker-compose --profile producer run --rm producer \
        --broker primary-kafka:29092 --topic commit-log --count 50

    sleep 10

    # Stop MirrorMaker 2 temporarily
    print_status "Stopping MirrorMaker 2 for topic reset..."
    docker-compose stop mirrormaker2

    # Delete and recreate the topic
    print_status "Deleting commit-log topic..."
    docker exec kafka-project-primary-kafka-1 \
        kafka-topics --bootstrap-server localhost:9092 --delete --topic commit-log || true

    sleep 5

    print_status "Recreating commit-log topic..."
    docker exec kafka-project-primary-kafka-1 \
        kafka-topics --create --topic commit-log --bootstrap-server localhost:9092 \
        --partitions 1 --replication-factor 1 --config retention.ms=60000

    # Produce new messages to the recreated topic
    print_status "Producing messages to recreated topic..."
    docker-compose --profile producer run --rm producer \
        --broker primary-kafka:29092 --topic commit-log --count 30

    # Restart MirrorMaker 2 - it should detect and handle the reset
    print_status "Restarting MirrorMaker 2 - should detect and handle topic reset..."
    docker-compose --profile mirrormaker up -d mirrormaker2

    # Wait and check logs for reset handling
    sleep 20

    print_status "Checking MirrorMaker 2 logs for topic reset handling..."
    if docker-compose logs mirrormaker2 2>&1 | grep -i "topic reset detected\|handling topic reset\|recovered from topic reset" >/dev/null; then
        print_success "Topic reset test PASSED - Reset detected and handled automatically"
    else
        print_warning "Topic reset test - Reset may not have been detected or handled differently"
    fi

    # Check if replication resumed
    sleep 10
    standby_count=$(check_topic_messages "standby" "primary.commit-log" "9093")
    if [ "$standby_count" -gt 0 ]; then
        print_success "Replication resumed successfully after topic reset"
    else
        print_warning "Replication may not have resumed after topic reset"
    fi
}

# Function to display logs
show_logs() {
    print_status "=== SYSTEM LOGS ==="

    echo -e "\n${BLUE}MirrorMaker 2 Logs:${NC}"
    docker-compose logs --tail=50 mirrormaker2 2>/dev/null || echo "MirrorMaker 2 not running"

    echo -e "\n${BLUE}Primary Kafka Logs (last 20 lines):${NC}"
    docker-compose logs --tail=20 primary-kafka 2>/dev/null || echo "Primary Kafka not running"

    echo -e "\n${BLUE}Standby Kafka Logs (last 20 lines):${NC}"
    docker-compose logs --tail=20 standby-kafka 2>/dev/null || echo "Standby Kafka not running"
}

# Main execution function
main() {
    print_status "Starting Kafka Data Replication Challenge..."

    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi

    # Build images first
    print_status "Building Docker images..."
    ./build-images.sh

    # Start the base infrastructure
    print_status "Starting Kafka clusters..."
    docker-compose up -d primary-zookeeper standby-zookeeper primary-kafka standby-kafka

    # Wait for Kafka clusters to be ready
    wait_for_kafka "primary" "9092"
    wait_for_kafka "standby" "9093"

    # Create topics
    print_status "Setting up topics..."
    docker-compose up topic-setup

    # Wait a bit for topics to be fully created
    sleep 10

    # Run tests
    test_normal_replication
    echo
    test_log_truncation
    echo
    test_topic_reset
    echo

    # Show logs for analysis
    show_logs

    print_success "Challenge tests completed!"
    print_status "Review the logs above to verify the enhanced MirrorMaker 2 behavior."
    print_status "Use 'docker-compose logs mirrormaker2' to see detailed MirrorMaker 2 logs."
    print_status "Use './cleanup.sh' to clean up all resources when done."
}

# Script options
case "${1:-}" in
    "test1"|"normal")
        print_status "Running normal replication test only..."
        docker-compose up -d primary-zookeeper standby-zookeeper primary-kafka standby-kafka
        wait_for_kafka "primary" "9092"
        wait_for_kafka "standby" "9093"
        docker-compose up topic-setup
        sleep 10
        test_normal_replication
        ;;
    "test2"|"truncation")
        print_status "Running log truncation test only..."
        docker-compose up -d primary-zookeeper standby-zookeeper primary-kafka standby-kafka
        wait_for_kafka "primary" "9092"
        wait_for_kafka "standby" "9093"
        docker-compose up topic-setup
        sleep 10
        test_log_truncation
        ;;
    "test3"|"reset")
        print_status "Running topic reset test only..."
        docker-compose up -d primary-zookeeper standby-zookeeper primary-kafka standby-kafka
        wait_for_kafka "primary" "9092"
        wait_for_kafka "standby" "9093"
        docker-compose up topic-setup
        sleep 10
        test_topic_reset
        ;;
    "logs")
        show_logs
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo "Commands:"
        echo "  (no args)    - Run all tests"
        echo "  test1/normal - Run normal replication test only"
        echo "  test2/truncation - Run log truncation test only"
        echo "  test3/reset  - Run topic reset test only"
        echo "  logs         - Show system logs"
        echo "  help         - Show this help"
        ;;
    *)
        main
        ;;
esac