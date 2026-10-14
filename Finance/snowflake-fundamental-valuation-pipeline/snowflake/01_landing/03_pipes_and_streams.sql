/* =============================================================================
   LANDING 03 - Snowpipes (continuous file ingestion) + Streams (CDC)
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   PIPES
   A pipe wraps a COPY INTO statement and runs it on SERVERLESS compute,
   billed per GB ingested, with no warehouse to size or resume. Each file is
   loaded once only: the pipe keeps 14 days of load history, so re-staging the
   same file does not create duplicates.

   How a pipe learns that new files have arrived:
     - External stage (S3/GCS/Azure): AUTO_INGEST = TRUE + cloud event
       notifications (S3 -> SQS queue owned by Snowflake). See 99_production_variants/.
     - Internal stage (this project): AUTO_INGEST = FALSE, because internal
       stages emit no cloud events. Two ways to trigger the pipe:
         1. Snowpipe REST API (insertFiles), usually from the upload script.
         2. ALTER PIPE ... REFRESH: queues every file staged in the last
            7 days that is not loaded yet. OPS.SP_INGEST_LANDING does this
            as the first step of the on-demand task graph.

   STREAMS
   A stream is a change-tracking offset on a table. Selecting from it returns
   only rows added since the last time the stream was consumed by a committed
   DML statement. APPEND_ONLY streams suit insert-only raw tables and are
   cheaper to compute than standard (insert/update/delete) streams.
   Staleness: a stream must be consumed within the table's retention period,
   which Snowflake extends up to MAX_DATA_EXTENSION_TIME_IN_DAYS (default 14).
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.LANDING;

-- ---------------------------------------------------------------------------
-- Pipe 1: market prices (backfill + daily delta CSV files)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PIPE PIPE_MARKET_PRICES
  AUTO_INGEST = FALSE
  COMMENT = 'Loads Yahoo Finance price CSVs from @STG_MARKET_DATA/prices/'
AS
COPY INTO VALUATION_DB.LANDING.RAW_MARKET_PRICES (
    ticker, trade_date, open, high, low, close, adj_close, volume,
    dividends, stock_splits, source, extracted_at_utc,
    _source_file, _file_row_number, _file_last_modified)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
           METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_LAST_MODIFIED
    FROM @VALUATION_DB.LANDING.STG_MARKET_DATA/prices/
)
FILE_FORMAT = (FORMAT_NAME = 'VALUATION_DB.LANDING.FF_CSV_HEADER')
PATTERN = '.*prices_.*[.]csv([.]gz)?'
ON_ERROR = 'SKIP_FILE';     -- a corrupt file is skipped whole and reported in COPY_HISTORY

-- ---------------------------------------------------------------------------
-- Pipe 2: SEC companyfacts (one gzip JSON document per company)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PIPE PIPE_SEC_COMPANYFACTS
  AUTO_INGEST = FALSE
  COMMENT = 'Loads SEC companyfacts JSON from @STG_SEC_EDGAR/companyfacts/'
AS
COPY INTO VALUATION_DB.LANDING.RAW_SEC_COMPANYFACTS (
    payload, cik, entity_name, _source_file, _file_last_modified)
FROM (
    SELECT $1,
           $1:cik::NUMBER(10,0),
           $1:entityName::VARCHAR,
           METADATA$FILENAME,
           METADATA$FILE_LAST_MODIFIED
    FROM @VALUATION_DB.LANDING.STG_SEC_EDGAR/companyfacts/
)
FILE_FORMAT = (FORMAT_NAME = 'VALUATION_DB.LANDING.FF_JSON_DOCUMENT')
PATTERN = '.*CIK[0-9]{10}[.]json([.]gz)?'
ON_ERROR = 'SKIP_FILE';

-- ---------------------------------------------------------------------------
-- Streams on the raw tables: the incremental hand-off to the CURATED zone
-- ---------------------------------------------------------------------------
CREATE OR REPLACE STREAM STRM_RAW_MARKET_PRICES
  ON TABLE RAW_MARKET_PRICES
  APPEND_ONLY = TRUE
  COMMENT = 'New price rows not yet merged into CURATED.MARKET_PRICES_DAILY';

CREATE OR REPLACE STREAM STRM_RAW_SEC_COMPANYFACTS
  ON TABLE RAW_SEC_COMPANYFACTS
  APPEND_ONLY = TRUE
  COMMENT = 'New SEC documents not yet parsed into CURATED.SEC_FINANCIAL_FACTS';

-- Useful checks
--   SELECT SYSTEM$PIPE_STATUS('VALUATION_DB.LANDING.PIPE_MARKET_PRICES');
--   ALTER PIPE PIPE_MARKET_PRICES REFRESH;          -- manual trigger
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
--       TABLE_NAME => 'RAW_MARKET_PRICES', START_TIME => DATEADD(hour, -24, CURRENT_TIMESTAMP())));
--   SELECT SYSTEM$STREAM_HAS_DATA('STRM_RAW_MARKET_PRICES');
