/* =============================================================================
   LANDING 02 - Raw (bronze) tables
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   Design rules for raw tables
   - TRANSIENT: reproducible from the staged files, so Fail-safe storage
     (7 extra days, not user-accessible) would be cost with no benefit.
   - CSV columns land as VARCHAR (schema-on-read). A malformed value never
     rejects a whole file at ingestion; typing and validation happen in
     CURATED, where bad rows are quarantined with a reason.
   - JSON lands as VARIANT (one row per SEC document). Only the keys needed to
     route/partition the data (CIK, entity name) are promoted to columns.
   - Every row carries lineage metadata: source file, row number,
     file timestamp and load timestamp. This answers "where did this number come from?"
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.LANDING;

-- Daily OHLCV prices (backfill + daily delta files) - fed by Snowpipe
CREATE TRANSIENT TABLE IF NOT EXISTS RAW_MARKET_PRICES (
    ticker               VARCHAR,
    trade_date           VARCHAR,
    open                 VARCHAR,
    high                 VARCHAR,
    low                  VARCHAR,
    close                VARCHAR,
    adj_close            VARCHAR,
    volume               VARCHAR,
    dividends            VARCHAR,
    stock_splits         VARCHAR,
    source               VARCHAR,
    extracted_at_utc     VARCHAR,
    _source_file         VARCHAR,
    _file_row_number     NUMBER,
    _file_last_modified  TIMESTAMP_NTZ,
    _loaded_at           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Bronze: Yahoo Finance daily prices exactly as delivered (all VARCHAR)';

-- SEC companyfacts: one VARIANT document per company file - fed by Snowpipe
CREATE TRANSIENT TABLE IF NOT EXISTS RAW_SEC_COMPANYFACTS (
    payload              VARIANT,
    cik                  NUMBER(10,0),
    entity_name          VARCHAR,
    _source_file         VARCHAR,
    _file_last_modified  TIMESTAMP_NTZ,
    _loaded_at           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Bronze: SEC EDGAR XBRL companyfacts JSON, one document per company';

-- Reference snapshots (full refresh on every load; loaded by OPS.SP_LOAD_REFERENCE_DATA)
CREATE TRANSIENT TABLE IF NOT EXISTS RAW_STOCK_SPLITS (
    ticker               VARCHAR,
    split_date           VARCHAR,
    split_ratio          VARCHAR,
    source               VARCHAR,
    extracted_at_utc     VARCHAR,
    _source_file         VARCHAR,
    _loaded_at           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Bronze: stock split / corporate action history (snapshot)';

CREATE TRANSIENT TABLE IF NOT EXISTS RAW_TICKER_UNIVERSE (
    ticker               VARCHAR,
    company_name         VARCHAR,
    cik                  VARCHAR,
    cik_role             VARCHAR,
    sector_theme         VARCHAR,
    _source_file         VARCHAR,
    _loaded_at           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Bronze: the 50-ticker research universe and its SEC registrant(s) (snapshot)';

CREATE TRANSIENT TABLE IF NOT EXISTS RAW_SEC_TICKER_MAP (
    payload              VARIANT,
    _source_file         VARCHAR,
    _loaded_at           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Bronze: SEC company_tickers.json (ticker -> CIK mapping, snapshot)';
