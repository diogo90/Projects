/* =============================================================================
   CONSUMPTION 01 - Star schema (gold)
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   PERMANENT tables: this is what analysts, BI tools and dbt read. Time Travel
   + Fail-safe protect against a bad deploy, and zero-copy CLONE gives cheap
   dev/test copies.

     DIM_DATE  --<  FCT_DAILY_PRICES            grain: company x trading day
     DIM_DATE  --<  FCT_DAILY_VALUATION         grain: company x trading day
     DIM_COMPANY -< FCT_DAILY_PRICES / FCT_DAILY_VALUATION / FCT_FUNDAMENTALS_QUARTERLY
                    FCT_FUNDAMENTALS_QUARTERLY  grain: company x fiscal quarter

   CLUSTERING: no clustering keys are declared. Each table is a few MB, so a
   handful of micro-partitions, and Automatic Clustering would spend credits
   for no pruning gain. Instead, the build procedure inserts rows ORDER BY
   (trade_date, ticker), so micro-partitions are naturally clustered by date
   at no ongoing cost. See 06_performance/clustering_and_pruning.sql for the
   analysis and the keys to use if the universe grows to the full market.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.CONSUMPTION;

-- ---------------------------------------------------------------------------
-- Shared date dimension (conformed across all facts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE DIM_DATE (
    date_key          NUMBER(8,0)  NOT NULL,   -- YYYYMMDD smart key
    calendar_date     DATE         NOT NULL,
    year              NUMBER(4,0),
    quarter           NUMBER(1,0),
    year_quarter      VARCHAR(7),              -- 2026-Q3
    month             NUMBER(2,0),
    month_name        VARCHAR(3),
    week_of_year      NUMBER(2,0),
    day_of_week       NUMBER(1,0),             -- ISO: 1 = Monday
    day_name          VARCHAR(3),
    is_weekend        BOOLEAN,
    is_month_end      BOOLEAN,
    is_quarter_end    BOOLEAN,
    is_trading_day    BOOLEAN,                 -- maintained by SP_BUILD_CONSUMPTION from price data
    CONSTRAINT pk_dim_date PRIMARY KEY (date_key) RELY
)
COMMENT = 'Calendar dimension 2005-2030 shared by all facts';

INSERT INTO DIM_DATE
WITH d AS (
    -- ROW_NUMBER rather than raw SEQ4(): SEQ4 does not guarantee a gap-free sequence
    SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2005-01-01'::DATE) AS calendar_date
    FROM TABLE(GENERATOR(ROWCOUNT => 9496))          -- 2005-01-01 .. 2030-12-31
)
SELECT TO_NUMBER(TO_CHAR(calendar_date, 'YYYYMMDD')),
       calendar_date,
       YEAR(calendar_date),
       QUARTER(calendar_date),
       YEAR(calendar_date) || '-Q' || QUARTER(calendar_date),
       MONTH(calendar_date),
       MONTHNAME(calendar_date),
       WEEKISO(calendar_date),
       DAYOFWEEKISO(calendar_date),
       DAYNAME(calendar_date),
       DAYOFWEEKISO(calendar_date) IN (6, 7),
       calendar_date = LAST_DAY(calendar_date, 'month'),
       calendar_date = LAST_DAY(calendar_date, 'quarter'),
       FALSE
FROM d;

-- ---------------------------------------------------------------------------
-- Company dimension (SCD Type 1: attributes overwritten, surrogate key stable)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DIM_COMPANY (
    company_key       NUMBER(10,0) IDENTITY(1,1) NOT NULL,
    ticker            VARCHAR      NOT NULL,
    company_name      VARCHAR      NOT NULL,
    sector_theme      VARCHAR      NOT NULL,
    primary_cik       NUMBER(10,0) NOT NULL,
    sec_registrant_title VARCHAR,
    _updated_at       TIMESTAMP_LTZ,
    CONSTRAINT pk_dim_company PRIMARY KEY (company_key) RELY,
    CONSTRAINT uq_dim_company_ticker UNIQUE (ticker) RELY
)
COMMENT = 'One row per company in the universe (SCD1)';

-- ---------------------------------------------------------------------------
-- Daily market fact: prices + rolling technical metrics
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FCT_DAILY_PRICES (
    date_key              NUMBER(8,0)   NOT NULL,
    company_key           NUMBER(10,0)  NOT NULL,
    trade_date            DATE          NOT NULL,
    ticker                VARCHAR       NOT NULL,   -- degenerate attribute for convenience
    open_price            NUMBER(18,6),
    high_price            NUMBER(18,6),
    low_price             NUMBER(18,6),
    close_price           NUMBER(18,6),
    adj_close_price       NUMBER(18,6),
    volume                NUMBER(38,0),
    dollar_volume         NUMBER(38,2),
    daily_return          FLOAT,                    -- on adjusted close (total return)
    sma_30d               NUMBER(18,6),             -- 30-day simple moving average (close)
    sma_200d              NUMBER(18,6),
    volatility_30d_ann    FLOAT,                    -- stdev(daily returns, 30d) * sqrt(252)
    high_52w              NUMBER(18,6),
    low_52w               NUMBER(18,6),
    CONSTRAINT pk_fct_daily_prices PRIMARY KEY (company_key, date_key) RELY,
    CONSTRAINT fk_fdp_date    FOREIGN KEY (date_key)    REFERENCES DIM_DATE (date_key) RELY,
    CONSTRAINT fk_fdp_company FOREIGN KEY (company_key) REFERENCES DIM_COMPANY (company_key) RELY
)
COMMENT = 'Daily prices with 30/200-day moving averages, volatility and 52-week range';

-- ---------------------------------------------------------------------------
-- Quarterly fundamentals fact: discrete quarters, TTM roll-ups, leverage
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FCT_FUNDAMENTALS_QUARTERLY (
    company_key               NUMBER(10,0) NOT NULL,
    ticker                    VARCHAR      NOT NULL,
    fiscal_quarter_end        DATE         NOT NULL,
    known_date                DATE         NOT NULL,  -- latest filing date of ANY input: point-in-time availability
    revenue_q                 NUMBER(38,2),
    net_income_q              NUMBER(38,2),
    eps_diluted_q             NUMBER(18,6),           -- split-adjusted to today's share basis
    operating_cash_flow_q     NUMBER(38,2),
    revenue_ttm               NUMBER(38,2),
    net_income_ttm            NUMBER(38,2),
    eps_diluted_ttm           NUMBER(18,6),
    operating_cash_flow_ttm   NUMBER(38,2),
    total_assets              NUMBER(38,2),
    total_liabilities         NUMBER(38,2),
    is_liabilities_derived    BOOLEAN,                -- = liabilities_and_equity - equity_incl_nci
    total_equity              NUMBER(38,2),
    total_debt                NUMBER(38,2),           -- long-term debt + short-term borrowings
    cash_and_equivalents      NUMBER(38,2),
    debt_to_equity            FLOAT,
    liabilities_to_equity     FLOAT,
    net_margin_ttm            FLOAT,
    cash_conversion_ttm       FLOAT,                  -- operating cash flow / net income
    revenue_growth_yoy        FLOAT,                  -- TTM vs TTM four quarters earlier
    eps_growth_yoy            FLOAT,
    has_full_ttm              BOOLEAN,                -- 4 contiguous quarters available
    CONSTRAINT pk_fct_fundamentals_quarterly PRIMARY KEY (company_key, fiscal_quarter_end) RELY,
    CONSTRAINT fk_ffq_company FOREIGN KEY (company_key) REFERENCES DIM_COMPANY (company_key) RELY
)
COMMENT = 'Quarterly fundamentals (as first reported) with trailing-twelve-month roll-ups';

-- ---------------------------------------------------------------------------
-- Daily valuation fact: prices x latest KNOWN fundamentals (ASOF join)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS FCT_DAILY_VALUATION (
    date_key                  NUMBER(8,0)   NOT NULL,
    company_key               NUMBER(10,0)  NOT NULL,
    trade_date                DATE          NOT NULL,
    ticker                    VARCHAR       NOT NULL,
    close_price               NUMBER(18,6),
    fiscal_quarter_end        DATE,                   -- which quarter the ratios are based on
    fundamentals_known_date   DATE,
    days_since_known          NUMBER(6,0),
    eps_diluted_ttm           NUMBER(18,6),
    pe_ratio                  FLOAT,                  -- NULL when TTM EPS <= 0 (not meaningful)
    earnings_yield            FLOAT,                  -- EPS / price (defined for losses too)
    debt_to_equity            FLOAT,
    liabilities_to_equity     FLOAT,
    net_margin_ttm            FLOAT,
    revenue_growth_yoy        FLOAT,
    is_loss_making            BOOLEAN,
    is_fundamentals_stale     BOOLEAN,                -- no new filing for > 135 days
    CONSTRAINT pk_fct_daily_valuation PRIMARY KEY (company_key, date_key) RELY,
    CONSTRAINT fk_fdv_date    FOREIGN KEY (date_key)    REFERENCES DIM_DATE (date_key) RELY,
    CONSTRAINT fk_fdv_company FOREIGN KEY (company_key) REFERENCES DIM_COMPANY (company_key) RELY
)
COMMENT = 'Daily point-in-time valuation multiples (no look-ahead bias)';

-- Analyst access to the gold tables
GRANT SELECT ON ALL TABLES IN SCHEMA VALUATION_DB.CONSUMPTION TO ROLE VALUATION_ANALYST;
