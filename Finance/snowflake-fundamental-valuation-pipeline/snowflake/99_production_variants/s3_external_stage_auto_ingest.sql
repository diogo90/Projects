/* =============================================================================
   PRODUCTION VARIANT (reference only, not executed in this project)
   S3 landing bucket + storage integration + Snowpipe AUTO_INGEST via SQS
   -----------------------------------------------------------------------------
   In production the landing zone would be an S3 bucket written by the
   extractors (Lambda / Airflow / ECS job). Snowpipe then becomes fully event-driven:

     extractor --PUT--> s3://fin-landing/prices/2026-10-14.csv
                          |  S3 event notification (ObjectCreated)
                          v
               Snowflake-managed SQS queue (one per account/region)
                          |
                          v
               PIPE (AUTO_INGEST = TRUE) --COPY--> RAW table --> STREAM --> TASK

   No polling, no REFRESH, no orchestration step for ingestion.
============================================================================= */
USE ROLE ACCOUNTADMIN;

-- 1. Trust relationship between Snowflake and an IAM role (no keys stored)
CREATE STORAGE INTEGRATION IF NOT EXISTS SI_FIN_LANDING
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<account-id>:role/snowflake-fin-landing'
  STORAGE_ALLOWED_LOCATIONS = ('s3://fin-landing/');

-- Returns STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID to paste into the
-- IAM role's trust policy in AWS.
DESC INTEGRATION SI_FIN_LANDING;
GRANT USAGE ON INTEGRATION SI_FIN_LANDING TO ROLE VALUATION_PIPELINE;

USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.LANDING;

-- 2. External stage on the bucket
CREATE STAGE IF NOT EXISTS EXT_STG_MARKET_DATA
  URL = 's3://fin-landing/market/'
  STORAGE_INTEGRATION = SI_FIN_LANDING
  FILE_FORMAT = FF_CSV_HEADER;

-- 3. Auto-ingest pipe: same COPY as the internal-stage pipe
CREATE OR REPLACE PIPE PIPE_MARKET_PRICES_S3
  AUTO_INGEST = TRUE
AS
COPY INTO RAW_MARKET_PRICES (
    ticker, trade_date, open, high, low, close, adj_close, volume,
    dividends, stock_splits, source, extracted_at_utc,
    _source_file, _file_row_number, _file_last_modified)
FROM (SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
             METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
      FROM @EXT_STG_MARKET_DATA/prices/)
PATTERN = '.*prices_.*[.]csv([.]gz)?';

-- 4. The "notification_channel" column holds the ARN of the Snowflake-managed SQS queue.
--    In AWS: S3 bucket > Properties > Event notifications > Create:
--      events = s3:ObjectCreated:*, prefix = market/prices/, destination = SQS queue ARN above.
SHOW PIPES LIKE 'PIPE_MARKET_PRICES_S3';

-- 5. One-off backfill of files that were in the bucket before the notification existed
ALTER PIPE PIPE_MARKET_PRICES_S3 REFRESH;

/* Alternative trigger for INTERNAL stages from code: the Snowpipe REST API
   (insertFiles endpoint, key-pair JWT auth), e.g. with the Python SDK
   `snowflake-ingest`:
       from snowflake.ingest import SimpleIngestManager, StagedFile
       mgr = SimpleIngestManager(account=..., host=..., user=..., pipe='VALUATION_DB.LANDING.PIPE_MARKET_PRICES',
                                 private_key=pem_private_key)
       mgr.ingest_files([StagedFile('daily/prices_2026-10-14.csv', None)])
   This project uses ALTER PIPE ... REFRESH instead (no key-pair setup needed). */
