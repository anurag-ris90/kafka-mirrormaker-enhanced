#!/usr/bin/env python3

import argparse
import json
import time
import uuid
import random
from kafka import KafkaProducer
from kafka.errors import KafkaError

def generate_event():
    """Generate a JSON event with required schema."""
    event_id = str(uuid.uuid4())
    timestamp = int(time.time())
    op_types = ['CREATE', 'UPDATE', 'DELETE']
    op_type = random.choice(op_types)
    key = f"doc:{random.randint(1000, 9999):04x}"

    # Generate appropriate status based on operation type
    if op_type == 'DELETE':
        status = 'deleted'
    elif op_type == 'CREATE':
        status = 'active'
    else:  # UPDATE
        status = 'archived'

    event = {
        "event_id": event_id,
        "timestamp": timestamp,
        "op_type": op_type,
        "key": key,
        "value": {
            "status": status
        }
    }

    return event

def main():
    parser = argparse.ArgumentParser(description='Commit Log Producer - Generate JSON events to Kafka')
    parser.add_argument('--count', '-c', type=int, default=10,
                        help='Number of messages to produce (default: 10)')
    parser.add_argument('--broker', '-b', type=str, default='localhost:9092',
                        help='Kafka broker address (default: localhost:9092)')
    parser.add_argument('--topic', '-t', type=str, default='commit-log',
                        help='Target topic name (default: commit-log)')

    args = parser.parse_args()

    print(f"Connecting to Kafka broker: {args.broker}")

    # Configure Kafka producer
    producer_config = {
        'bootstrap_servers': [args.broker],
        'value_serializer': lambda v: json.dumps(v).encode('utf-8'),
        'key_serializer': lambda k: k.encode('utf-8') if k else None,
        'acks': 'all',
        'retries': 3,
        'batch_size': 16384,
        'linger_ms': 5
    }

    try:
        producer = KafkaProducer(**producer_config)
        print("Connected successfully")

        print(f"Producing {args.count} messages to topic: {args.topic}")

        # Generate and send messages
        successful_sends = 0

        for i in range(args.count):
            event = generate_event()
            key = event['key']

            try:
                # Send message and get future
                future = producer.send(args.topic, key=key, value=event)

                # Wait for the send to complete (optional, for better error handling)
                record_metadata = future.get(timeout=10)
                successful_sends += 1

                # Log progress for larger batches
                if args.count > 50 and (i + 1) % 10 == 0:
                    print(f"Sent {i + 1}/{args.count} messages...")

            except KafkaError as e:
                print(f"Failed to send message {i + 1}: {e}")

        # Ensure all messages are sent
        producer.flush()

        print(f"Successfully produced {successful_sends} messages")

        if successful_sends > 0:
            # Get the last record metadata for partition info
            last_future = producer.send(args.topic, key='test', value={'test': 'metadata'})
            last_metadata = last_future.get(timeout=10)

            print("Partition results:")
            print(f"  Topic: {last_metadata.topic}")
            print(f"  Partition: {last_metadata.partition}")
            print(f"  Offset: {last_metadata.offset}")

        print("Producer disconnected")

    except Exception as e:
        print(f"Error connecting to Kafka: {e}")
        exit(1)

    finally:
        if 'producer' in locals():
            producer.close()

if __name__ == "__main__":
    main()