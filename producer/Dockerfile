FROM python:3.11-slim

WORKDIR /app

# Install requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the producer script
COPY producer.py .

# Make the script executable
RUN chmod +x producer.py

# Set the entrypoint
ENTRYPOINT ["python", "producer.py"]