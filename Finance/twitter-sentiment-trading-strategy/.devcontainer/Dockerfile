ARG PLATFORM=amd64
# FROM --platform=linux/${PLATFORM} python:3.11
FROM mcr.microsoft.com/devcontainers/python:3.11

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Poetry
RUN pip install poetry --no-cache-dir

# Configure Poetry to create .venv inside the project
RUN poetry config virtualenvs.in-project true

# Set working directory
WORKDIR /workspace
