#!/usr/bin/env bash
# Upload the locally sourced data to the S3 bronze layer.
# `sync` only copies new/changed files, so re-running after a new download is incremental.
#
# Usage:  BUCKET=football-analytics-moneyball-123456789012 ./scripts/upload_to_s3.sh
set -euo pipefail
: "${BUCKET:?Set BUCKET to your project bucket name}"

aws s3 sync data/raw_to_s3/dataset_1/statsbomb      "s3://${BUCKET}/bronze/statsbomb"      --exclude "*" --include "*.json"
aws s3 sync data/raw_to_s3/dataset_2/transfermarkt  "s3://${BUCKET}/bronze/transfermarkt"  --exclude "*" --include "*.csv"

aws s3 ls "s3://${BUCKET}/bronze/" --recursive --summarize | tail -2
