/* =============================================================================
   CURATED 02 - Curated (silver) tables
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   Curated = typed, validated, de-duplicated and conformed, but still
   source-shaped. No business metrics live here; those belong to CONSUMPTION.
   Constraints (PK/FK) are informational in Snowflake (not enforced, except
   NOT NULL). They are declared anyway because they document the grain, and
   BI tools and the optimiser can use them (RELY).
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.CURATED;

-- ---------------------------------------------------------------------------
-- Security master + SEC entity bridge (ticker <-> CIK is ONE-TO-MANY:
-- e.g. XOM moved to a new holding-company registrant in 2026, so its
-- history sits under the predecessor CIK and new filings under the successor)
-- ---------------------------------------------------------------------------
CREATE TRANSIENT TABLE IF NOT EXISTS SECURITY_MASTER (
    ticker               VARCHAR      NOT NULL,
    company_name         VARCHAR      NOT NULL,
    sector_theme         VARCHAR      NOT NULL,
    primary_cik          NUMBER(10,0) NOT NULL,
    sec_registrant_title VARCHAR,                 -- from SEC company_tickers.json
    is_cik_validated     BOOLEAN,                 -- primary CIK matches SEC's current map
    _updated_at          TIMESTAMP_LTZ,
    CONSTRAINT pk_security_master PRIMARY KEY (ticker) RELY
)
COMMENT = 'One row per ticker in the research universe';

CREATE TRANSIENT TABLE IF NOT EXISTS SEC_ENTITY_MAP (
    ticker               VARCHAR      NOT NULL,
    cik                  NUMBER(10,0) NOT NULL,
    cik_role             VARCHAR      NOT NULL,   -- primary | predecessor
    _updated_at          TIMESTAMP_LTZ,
    CONSTRAINT pk_sec_entity_map PRIMARY KEY (ticker, cik) RELY
)
COMMENT = 'Bridge: SEC registrant (CIK) -> market ticker';

CREATE TRANSIENT TABLE IF NOT EXISTS STOCK_SPLITS (
    ticker               VARCHAR       NOT NULL,
    split_date           DATE          NOT NULL,
    split_ratio          NUMBER(18,8)  NOT NULL,  -- new shares per old share (0.125 = 1:8 reverse)
    _updated_at          TIMESTAMP_LTZ,
    CONSTRAINT pk_stock_splits PRIMARY KEY (ticker, split_date) RELY
)
COMMENT = 'Corporate actions used to put per-share SEC values on the price basis';

-- ---------------------------------------------------------------------------
-- Market prices: incremental MERGE target fed by LANDING.STRM_RAW_MARKET_PRICES
-- ---------------------------------------------------------------------------
CREATE TRANSIENT TABLE IF NOT EXISTS MARKET_PRICES_DAILY (
    ticker               VARCHAR       NOT NULL,
    trade_date           DATE          NOT NULL,
    open_price           NUMBER(18,6),
    high_price           NUMBER(18,6),
    low_price            NUMBER(18,6),
    close_price          NUMBER(18,6)  NOT NULL,   -- split-adjusted, not dividend-adjusted
    adj_close_price      NUMBER(18,6),             -- split- and dividend-adjusted
    volume               NUMBER(38,0),
    dividend_per_share   NUMBER(18,6),
    split_ratio          NUMBER(18,8),
    record_hash          VARCHAR       NOT NULL,   -- change detection for late corrections
    _source_file         VARCHAR,
    _first_loaded_at     TIMESTAMP_LTZ,
    _updated_at          TIMESTAMP_LTZ,
    CONSTRAINT pk_market_prices_daily PRIMARY KEY (ticker, trade_date) RELY
)
COMMENT = 'Typed, de-duplicated daily OHLCV (one row per ticker per trading day)';

CREATE TRANSIENT TABLE IF NOT EXISTS MARKET_PRICES_QUARANTINE (
    ticker               VARCHAR,
    trade_date           VARCHAR,
    close                VARCHAR,
    raw_record           VARIANT,
    reject_reason        VARCHAR,
    _source_file         VARCHAR,
    _quarantined_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Rows that failed type or business validation, kept with a reason (never silently dropped)';

-- ---------------------------------------------------------------------------
-- SEC facts: every XBRL fact for the universe, flattened from the VARIANT
-- documents by the Snowpark procedure OPS.SP_CURATE_SEC_FUNDAMENTALS
-- ---------------------------------------------------------------------------
CREATE TRANSIENT TABLE IF NOT EXISTS SEC_FINANCIAL_FACTS (
    fact_id              VARCHAR       NOT NULL,   -- SHA2 of the natural key (period_start can be NULL)
    cik                  NUMBER(10,0)  NOT NULL,
    taxonomy             VARCHAR       NOT NULL,   -- us-gaap | dei | srt | ...
    concept              VARCHAR       NOT NULL,
    unit                 VARCHAR       NOT NULL,
    period_start         DATE,                     -- NULL for INSTANT (balance-sheet) facts
    period_end           DATE          NOT NULL,
    value                NUMBER(38,6)  NOT NULL,
    accession_no         VARCHAR       NOT NULL,   -- SEC filing id
    form                 VARCHAR,                  -- 10-K | 10-Q | 8-K | 10-K/A ...
    filed_date           DATE          NOT NULL,   -- when the market could know the number
    fiscal_year          NUMBER(4,0),
    fiscal_period        VARCHAR,                  -- FY | Q1 | Q2 | Q3
    frame                VARCHAR,                  -- SEC calendar frame, e.g. CY2024Q3
    _source_file         VARCHAR,
    _loaded_at           TIMESTAMP_LTZ,
    -- natural key: cik, taxonomy, concept, unit, period_start, period_end, accession_no
    CONSTRAINT pk_sec_financial_facts PRIMARY KEY (fact_id) RELY
)
COMMENT = 'Long/narrow table of every XBRL fact (all concepts kept for future metrics)';

-- Standardised metric layer: concept map applied, first-reported value kept
CREATE TRANSIENT TABLE IF NOT EXISTS SEC_FUNDAMENTALS_STD (
    ticker               VARCHAR       NOT NULL,
    cik                  NUMBER(10,0)  NOT NULL,
    metric               VARCHAR       NOT NULL,
    value_kind           VARCHAR       NOT NULL,   -- DURATION | INSTANT
    is_per_share         BOOLEAN       NOT NULL,
    period_start         DATE,
    period_end           DATE          NOT NULL,
    period_days          NUMBER(5,0),
    value                NUMBER(38,6)  NOT NULL,
    source_concept       VARCHAR       NOT NULL,
    concept_priority     NUMBER(3,0)   NOT NULL,
    accession_no         VARCHAR       NOT NULL,
    form                 VARCHAR,
    filed_date           DATE          NOT NULL,
    fiscal_year          NUMBER(4,0),
    fiscal_period        VARCHAR,
    _built_at            TIMESTAMP_LTZ
)
COMMENT = 'One value per ticker x metric x period, as FIRST reported (point-in-time safe)';
