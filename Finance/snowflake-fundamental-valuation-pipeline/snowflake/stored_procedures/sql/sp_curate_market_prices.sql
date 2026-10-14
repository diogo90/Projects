/* =============================================================================
   OPS.SP_CURATE_MARKET_PRICES  - incremental LANDING -> CURATED for prices
   -----------------------------------------------------------------------------
   Pattern: Stream -> typed batch -> (quarantine bad rows) + MERGE good rows

   - Reads ONLY new raw rows (APPEND_ONLY stream), so a daily delta file costs
     the same whether the table holds 5 or 50 years of history.
   - Explicit transaction: the stream offset advances only when the
     transaction COMMITs. The quarantine INSERT and the MERGE see the
     same change set; on any error everything rolls back and the stream
     still holds the batch for the next run (at-least-once, idempotent).
   - Idempotent upsert: MERGE on (ticker, trade_date). Re-delivered rows with
     identical values are ignored. Corrected values (e.g. a vendor restating
     a close price) UPDATE the row, detected via record_hash.
   - In-batch de-duplication: if a backfill and a delta file both contain the
     same day, the most recently modified file wins.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE OR REPLACE PROCEDURE SP_CURATE_MARKET_PRICES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Stream-driven MERGE of new raw prices into CURATED.MARKET_PRICES_DAILY'
AS
$$
DECLARE
    started_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    n_batch      NUMBER DEFAULT 0;
    n_rejected   NUMBER DEFAULT 0;
    n_inserted   NUMBER DEFAULT 0;
    n_updated    NUMBER DEFAULT 0;
    merge_qid    VARCHAR;
    result       VARIANT;
BEGIN
    IF (NOT SYSTEM$STREAM_HAS_DATA('VALUATION_DB.LANDING.STRM_RAW_MARKET_PRICES')) THEN
        INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
            SELECT 'SP_CURATE_MARKET_PRICES', 'SKIPPED', OBJECT_CONSTRUCT('reason', 'stream empty'), :started_at;
        RETURN OBJECT_CONSTRUCT('status', 'SKIPPED', 'reason', 'stream empty');
    END IF;

    -- DDL commits implicitly, so the temp table is created BEFORE the transaction
    CREATE OR REPLACE TEMPORARY TABLE VALUATION_DB.CURATED.TMP_PRICE_BATCH (
        ticker VARCHAR, trade_date DATE, open_price NUMBER(18,6), high_price NUMBER(18,6),
        low_price NUMBER(18,6), close_price NUMBER(18,6), adj_close_price NUMBER(18,6),
        volume NUMBER(38,0), dividend_per_share NUMBER(18,6), split_ratio NUMBER(18,8),
        record_hash VARCHAR, reject_reason VARCHAR, raw_record VARIANT,
        _source_file VARCHAR, _file_last_modified TIMESTAMP_NTZ, _file_row_number NUMBER);

    BEGIN TRANSACTION;

    -- 1. Type + validate the stream content (consumes the stream at COMMIT)
    INSERT INTO VALUATION_DB.CURATED.TMP_PRICE_BATCH
    WITH typed AS (
        SELECT UPPER(TRIM(ticker))                 AS ticker,
               TRY_TO_DATE(trade_date)             AS trade_date,
               TRY_TO_NUMBER(open, 18, 6)          AS open_price,
               TRY_TO_NUMBER(high, 18, 6)          AS high_price,
               TRY_TO_NUMBER(low, 18, 6)           AS low_price,
               TRY_TO_NUMBER(close, 18, 6)         AS close_price,
               TRY_TO_NUMBER(adj_close, 18, 6)     AS adj_close_price,
               TRY_TO_NUMBER(volume)               AS volume,
               COALESCE(TRY_TO_NUMBER(dividends, 18, 6), 0)    AS dividend_per_share,
               COALESCE(TRY_TO_NUMBER(stock_splits, 18, 8), 0) AS split_ratio,
               OBJECT_CONSTRUCT_KEEP_NULL(*)       AS raw_record,
               _source_file, _file_last_modified, _file_row_number
        FROM VALUATION_DB.LANDING.STRM_RAW_MARKET_PRICES
        WHERE METADATA$ACTION = 'INSERT'
    )
    SELECT ticker, trade_date, open_price, high_price, low_price, close_price, adj_close_price,
           volume, dividend_per_share, split_ratio,
           -- HASH() is NULL-safe (CONCAT_WS would return NULL if any input is NULL)
           TO_VARCHAR(HASH(open_price, high_price, low_price, close_price,
                           adj_close_price, volume, dividend_per_share, split_ratio)),
           CASE
               WHEN ticker IS NULL OR trade_date IS NULL       THEN 'missing key (ticker/trade_date)'
               WHEN close_price IS NULL OR close_price <= 0    THEN 'close price missing or non-positive'
               WHEN open_price IS NULL OR high_price IS NULL OR low_price IS NULL THEN 'missing OHLC value'
               WHEN high_price < low_price                     THEN 'high < low'
               WHEN close_price NOT BETWEEN low_price AND high_price THEN 'close outside [low, high]'
               WHEN volume < 0                                 THEN 'negative volume'
               WHEN trade_date > CURRENT_DATE()                THEN 'trade date in the future'
           END,
           raw_record, _source_file, _file_last_modified, _file_row_number
    FROM typed;

    -- 2. Quarantine rejected rows with their reason
    INSERT INTO VALUATION_DB.CURATED.MARKET_PRICES_QUARANTINE
        (ticker, trade_date, close, raw_record, reject_reason, _source_file)
    SELECT ticker, raw_record:TRADE_DATE::VARCHAR, raw_record:CLOSE::VARCHAR,
           raw_record, reject_reason, _source_file
    FROM VALUATION_DB.CURATED.TMP_PRICE_BATCH
    WHERE reject_reason IS NOT NULL;

    -- 3. Upsert valid rows (latest file wins inside the batch)
    MERGE INTO VALUATION_DB.CURATED.MARKET_PRICES_DAILY AS tgt
    USING (
        SELECT *
        FROM VALUATION_DB.CURATED.TMP_PRICE_BATCH
        WHERE reject_reason IS NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ticker, trade_date
                                   ORDER BY _file_last_modified DESC, _source_file DESC,
                                            _file_row_number DESC) = 1
    ) AS src
      ON tgt.ticker = src.ticker
     AND tgt.trade_date = src.trade_date
    WHEN MATCHED AND tgt.record_hash <> src.record_hash THEN UPDATE SET
         open_price = src.open_price, high_price = src.high_price, low_price = src.low_price,
         close_price = src.close_price, adj_close_price = src.adj_close_price,
         volume = src.volume, dividend_per_share = src.dividend_per_share,
         split_ratio = src.split_ratio, record_hash = src.record_hash,
         _source_file = src._source_file, _updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (ticker, trade_date, open_price, high_price, low_price, close_price, adj_close_price,
         volume, dividend_per_share, split_ratio, record_hash, _source_file,
         _first_loaded_at, _updated_at)
    VALUES
        (src.ticker, src.trade_date, src.open_price, src.high_price, src.low_price,
         src.close_price, src.adj_close_price, src.volume, src.dividend_per_share,
         src.split_ratio, src.record_hash, src._source_file,
         CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
    merge_qid := SQLID;

    COMMIT;

    SELECT "number of rows inserted", "number of rows updated"
      INTO :n_inserted, :n_updated
      FROM TABLE(RESULT_SCAN(:merge_qid));
    SELECT COUNT(*), COUNT_IF(reject_reason IS NOT NULL)
      INTO :n_batch, :n_rejected
      FROM VALUATION_DB.CURATED.TMP_PRICE_BATCH;

    result := OBJECT_CONSTRUCT('rows_in_batch', n_batch, 'rows_rejected', n_rejected,
                               'rows_inserted', n_inserted, 'rows_updated', n_updated);
    INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
        SELECT 'SP_CURATE_MARKET_PRICES', 'SUCCEEDED', :result, :started_at;
    RETURN result;

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;   -- stream offset is NOT advanced: the batch will be retried
        INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
            SELECT 'SP_CURATE_MARKET_PRICES', 'FAILED',
                   OBJECT_CONSTRUCT('sqlcode', :SQLCODE, 'sqlerrm', :SQLERRM, 'sqlstate', :SQLSTATE),
                   :started_at;
        RAISE;
END;
$$;
