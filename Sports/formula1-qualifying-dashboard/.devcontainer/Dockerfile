FROM mcr.microsoft.com/devcontainers/python:3.11

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Poetry
RUN pip install --no-cache-dir poetry==1.8.2

# Set working directory (this will be the mount point for the repo)
WORKDIR /app

# Optionally copy dependency files for future optimization,
# but do NOT run `poetry install` here.
COPY pyproject.toml poetry.lock* /app/