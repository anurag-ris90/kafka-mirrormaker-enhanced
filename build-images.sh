#!/bin/bash
set -e

echo "Building Python Commit Log Producer Docker image..."

# Build the producer image
cd producer
docker build -t commit-log-producer:latest .
cd ..

echo "Docker images built successfully!"
echo "Available images:"
docker images | grep -E "(commit-log-producer)"

echo ""
echo "Producer capabilities:"
echo "  - Python-based CLI with argparse"
echo "  - JSON event generation with UUIDs and timestamps"
echo "  - Progress tracking for large batches"
echo "  - Configurable broker, topic, and message count"
echo ""
echo "Note: Enhanced MirrorMaker 2 would require building from Kafka v4.0.0 source"
echo "The enhanced source code is available in: src/kafka/connect/mirror/src/main/java/org/apache/kafka/connect/mirror/MirrorSourceTask.java"
echo "For production deployment, this would be compiled and deployed as custom JAR files."