# ------------------------------------------------------------------------------
# Makefile for the Twitter Sentiment Trading Strategy project
#
# This file defines small, repeatable automation commands ("targets") that make
# it easy to run parts of the project without remembering long Poetry commands.
#
# HOW TO USE:
#   make <target>
#
# EXAMPLES:
#   make pypi-ingest     → runs the ingestion pipeline script
#
# NOTES:
# - Targets do NOT run inside the Poetry environment automatically.
#   That's why each command explicitly uses `poetry run ...`.
# - This Makefile lives at the project root, but it can execute scripts located
#   anywhere in the repository.
# ------------------------------------------------------------------------------

# Run the ingestion pipeline as a standalone script.
pypi-ingest:
	poetry run python -m ingestion.pipeline

# Include this command to run tests 
test:
	poetry run pytest -v