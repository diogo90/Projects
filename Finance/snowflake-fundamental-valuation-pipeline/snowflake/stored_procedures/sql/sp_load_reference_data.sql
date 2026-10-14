/* =============================================================================
   OPS.SP_LOAD_REFERENCE_DATA
   -----------------------------------------------------------------------------
   Reference files are SNAPSHOTS (the whole universe, the whole split history,
   the whole SEC ticker map), not event streams. So they are not appended
   through a pipe; they are replaced on every run:
       TRUNCATE raw  ->  COPY INTO ... FORCE = TRUE  ->  rebuild curated
   FORCE = TRUE re-reads files even when the COPY load history says they were
   already loaded, which is what a full-refresh snapshot needs.

   Curated outputs: SECURITY_MASTER, SEC_ENTITY_MAP, STOCK_SPLITS
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE OR REPLACE PROCEDURE SP_LOAD_REFERENCE_DATA()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Full-refresh load of universe, split history and SEC ticker map'
AS
$$
DECLARE
    started_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    n_universe   NUMBER;
    n_splits     NUMBER;
    n_ticker_map NUMBER;
    n_unvalidated NUMBER;
    result       VARIANT;
BEGIN
    -- 1. Raw snapshots ---------------------------------------------------------
    TRUNCATE TABLE VALUATION_DB.LANDING.RAW_TICKER_UNIVERSE;
    COPY INTO VALUATION_DB.LANDING.RAW_TICKER_UNIVERSE
        (ticker, company_name, cik, cik_role, sector_theme, _source_file)
    FROM (SELECT $1, $2, $3, $4, $5, METADATA$FILENAME
          FROM @VALUATION_DB.LANDING.STG_MARKET_DATA/universe/)
    FILE_FORMAT = (FORMAT_NAME = 'VALUATION_DB.LANDING.FF_CSV_HEADER')
    PATTERN = '.*[.]csv([.]gz)?'
    FORCE = TRUE
    ON_ERROR = 'ABORT_STATEMENT';       -- reference data must be complete or not at all

    TRUNCATE TABLE VALUATION_DB.LANDING.RAW_STOCK_SPLITS;
    COPY INTO VALUATION_DB.LANDING.RAW_STOCK_SPLITS
        (ticker, split_date, split_ratio, source, extracted_at_utc, _source_file)
    FROM (SELECT $1, $2, $3, $4, $5, METADATA$FILENAME
          FROM @VALUATION_DB.LANDING.STG_MARKET_DATA/splits/)
    FILE_FORMAT = (FORMAT_NAME = 'VALUATION_DB.LANDING.FF_CSV_HEADER')
    PATTERN = '.*[.]csv([.]gz)?'
    FORCE = TRUE
    ON_ERROR = 'ABORT_STATEMENT';

    TRUNCATE TABLE VALUATION_DB.LANDING.RAW_SEC_TICKER_MAP;
    COPY INTO VALUATION_DB.LANDING.RAW_SEC_TICKER_MAP (payload, _source_file)
    FROM (SELECT $1, METADATA$FILENAME
          FROM @VALUATION_DB.LANDING.STG_SEC_EDGAR/ticker_map/)
    FILE_FORMAT = (FORMAT_NAME = 'VALUATION_DB.LANDING.FF_JSON_DOCUMENT')
    FORCE = TRUE
    ON_ERROR = 'ABORT_STATEMENT';

    -- 2. Curated: SEC entity bridge (ticker -> one or more CIKs) ----------------
    INSERT OVERWRITE INTO VALUATION_DB.CURATED.SEC_ENTITY_MAP (ticker, cik, cik_role, _updated_at)
    SELECT DISTINCT UPPER(TRIM(ticker)), TRY_TO_NUMBER(cik), LOWER(TRIM(cik_role)), CURRENT_TIMESTAMP()
    FROM VALUATION_DB.LANDING.RAW_TICKER_UNIVERSE
    WHERE TRY_TO_NUMBER(cik) IS NOT NULL;

    -- 3. Curated: security master, validated against the SEC's own ticker map --
    INSERT OVERWRITE INTO VALUATION_DB.CURATED.SECURITY_MASTER
        (ticker, company_name, sector_theme, primary_cik, sec_registrant_title, is_cik_validated, _updated_at)
    WITH sec_map AS (
        SELECT e.value:ticker::VARCHAR  AS ticker,
               e.value:cik_str::NUMBER  AS cik,
               e.value:title::VARCHAR   AS title
        FROM VALUATION_DB.LANDING.RAW_SEC_TICKER_MAP r,
             LATERAL FLATTEN(INPUT => r.payload) e       -- {"0": {...}, "1": {...}}
    ),
    universe AS (
        SELECT UPPER(TRIM(ticker)) AS ticker, TRIM(company_name) AS company_name,
               TRIM(sector_theme) AS sector_theme, TRY_TO_NUMBER(cik) AS cik
        FROM VALUATION_DB.LANDING.RAW_TICKER_UNIVERSE
        WHERE LOWER(TRIM(cik_role)) = 'primary'
        QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(ticker)) ORDER BY cik) = 1
    )
    SELECT u.ticker, u.company_name, u.sector_theme, u.cik,
           s.title,
           COALESCE(s.cik = u.cik, FALSE),
           CURRENT_TIMESTAMP()
    FROM universe u
    LEFT JOIN sec_map s ON s.ticker = u.ticker;

    -- 4. Curated: split history (typed, de-duplicated) -------------------------
    INSERT OVERWRITE INTO VALUATION_DB.CURATED.STOCK_SPLITS (ticker, split_date, split_ratio, _updated_at)
    SELECT UPPER(TRIM(ticker)), TRY_TO_DATE(split_date), TRY_TO_NUMBER(split_ratio, 18, 8), CURRENT_TIMESTAMP()
    FROM VALUATION_DB.LANDING.RAW_STOCK_SPLITS
    WHERE TRY_TO_DATE(split_date) IS NOT NULL
      AND TRY_TO_NUMBER(split_ratio, 18, 8) > 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(ticker)), TRY_TO_DATE(split_date)
                               ORDER BY _loaded_at DESC) = 1;

    SELECT COUNT(*) INTO :n_universe    FROM VALUATION_DB.CURATED.SECURITY_MASTER;
    SELECT COUNT(*) INTO :n_splits      FROM VALUATION_DB.CURATED.STOCK_SPLITS;
    SELECT COUNT(*) INTO :n_ticker_map  FROM VALUATION_DB.LANDING.RAW_SEC_TICKER_MAP;
    SELECT COUNT_IF(NOT is_cik_validated) INTO :n_unvalidated FROM VALUATION_DB.CURATED.SECURITY_MASTER;

    result := OBJECT_CONSTRUCT('securities', n_universe, 'splits', n_splits,
                               'ticker_map_documents', n_ticker_map,
                               'securities_failing_cik_validation', n_unvalidated);

    INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
        SELECT 'SP_LOAD_REFERENCE_DATA', 'SUCCEEDED', :result, :started_at;
    RETURN result;

EXCEPTION
    WHEN OTHER THEN
        INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
            SELECT 'SP_LOAD_REFERENCE_DATA', 'FAILED',
                   OBJECT_CONSTRUCT('sqlcode', :SQLCODE, 'sqlerrm', :SQLERRM, 'sqlstate', :SQLSTATE),
                   :started_at;
        RAISE;   -- re-throw so the task (and the graph) is marked FAILED
END;
$$;
