/* =============================================================================
   LANDING 01 - File formats and internal stages
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   STAGE vs LANDING ZONE
   A stage is a pointer to file storage, not a table. Here the LANDING zone
   is made of two parts:
     (a) the STAGE: immutable files exactly as delivered (the replayable
         source of truth), and
     (b) the RAW tables: the first queryable copy of those files, plus load
         metadata (file name, row number, load timestamp).
   In production, (a) is usually an S3/ADLS/GCS bucket exposed as an EXTERNAL
   stage, with lifecycle rules and, in practice, many teams owning it.
   This project uses INTERNAL named stages (Snowflake-managed storage), so no
   cloud account is needed. The SQL for the S3 + SQS variant is in
   99_production_variants/.

   Stage layout (upload paths in Snowsight > Data > Add Data > Load files to stage):
     @STG_MARKET_DATA/prices/backfill/   <- data/raw/dataset1/backfill/*.csv
     @STG_MARKET_DATA/prices/daily/      <- data/raw/dataset1/daily/*.csv
     @STG_MARKET_DATA/splits/            <- data/raw/dataset1/reference/stock_splits.csv
     @STG_MARKET_DATA/universe/          <- config/ticker_universe.csv
     @STG_SEC_EDGAR/companyfacts/        <- data/raw/dataset2/companyfacts/*.json.gz
     @STG_SEC_EDGAR/ticker_map/          <- data/raw/dataset2/reference/company_tickers.json.gz
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.LANDING;

-- ---------------------------------------------------------------------------
-- File formats: parsing rules defined once and reused by stages, pipes and COPY
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT FF_CSV_HEADER
  TYPE = CSV
  FIELD_DELIMITER = ','
  PARSE_HEADER = FALSE
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'null', 'NaN', 'nan')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE    -- schema drift fails loudly, not silently
  COMPRESSION = AUTO                       -- reads .csv and .csv.gz alike
  COMMENT = 'Comma-separated files with a single header row';

CREATE OR REPLACE FILE FORMAT FF_JSON_DOCUMENT
  TYPE = JSON
  STRIP_OUTER_ARRAY = FALSE   -- each SEC file is ONE JSON object = one row
  COMPRESSION = AUTO          -- SEC files are delivered as .json.gz
  COMMENT = 'One JSON document per file (SEC companyfacts / ticker map)';

-- ---------------------------------------------------------------------------
-- Internal named stages (one per source system = clean ownership & access)
-- DIRECTORY tables give a queryable file catalogue: SELECT * FROM DIRECTORY(@stage)
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS STG_MARKET_DATA
  FILE_FORMAT = FF_CSV_HEADER
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing area for Yahoo Finance extracts + ticker universe';

CREATE STAGE IF NOT EXISTS STG_SEC_EDGAR
  FILE_FORMAT = FF_JSON_DOCUMENT
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing area for SEC EDGAR companyfacts JSON + ticker map';

-- Stage for Python source code imported by the Snowpark stored procedure
CREATE STAGE IF NOT EXISTS VALUATION_DB.OPS.STG_CODE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Python modules for Snowpark stored procedures';

-- After uploading files:
--   ALTER STAGE STG_MARKET_DATA REFRESH;   -- refresh directory table
--   LIST @STG_MARKET_DATA;
--   SELECT relative_path, size, last_modified FROM DIRECTORY(@STG_MARKET_DATA);
