/* =============================================================================
   OPS.SP_BUILD_CONSUMPTION  - CURATED -> CONSUMPTION (gold star schema)
   -----------------------------------------------------------------------------
   Business rules implemented here (the "interesting" finance logic):

   1. SPLIT NORMALISATION. Yahoo back-adjusts the whole price history to
      today's share count; SEC per-share values (EPS) are on the share count at
      filing date. Each EPS fact is divided by the product of every split that
      happened AFTER its filing date, so price and EPS share one basis.
      Without this, NVDA's P/E around its 10:1 split (Jun 2024) is off by 10x.

   2. DISCRETE QUARTERS FROM YEAR-TO-DATE FIGURES. 10-Qs report YTD numbers
      (cash flow statements report ONLY YTD), and Q4 is never filed: it is
      FY minus the first three quarters. Facts sharing a period_start form a
      cumulative chain (Q1 -> H1 -> 9M -> FY); differencing consecutive links
      yields every discrete quarter, Q4 included. A directly reported 3-month
      value is preferred when one exists.

   3. TRAILING TWELVE MONTHS (TTM) only when 4 contiguous quarters exist.

   4. POINT-IN-TIME (no look-ahead bias). Each quarter carries known_date =
      the latest filing date of any of its inputs. Prices are joined to
      fundamentals with an ASOF JOIN on trade_date > known_date, so a
      backtest on any day uses only what had been filed before that day.

   Everything runs in ONE transaction: consumers never see a half-built gold
   layer. Full rebuilds (INSERT OVERWRITE) are deliberate: the whole gold
   layer is ~200k rows and rebuilds in seconds on an X-SMALL. Incremental
   logic would add complexity with no saving at this scale.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE OR REPLACE PROCEDURE SP_BUILD_CONSUMPTION()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Rebuilds dimensions and facts of the CONSUMPTION star schema'
AS
$$
DECLARE
    started_at  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
    n_prices    NUMBER;
    n_quarters  NUMBER;
    n_valuation NUMBER;
    result      VARIANT;
BEGIN
    BEGIN TRANSACTION;

    -- ------------------------------------------------------------------------
    -- DIM_COMPANY (SCD1 MERGE keeps surrogate keys stable across runs)
    -- ------------------------------------------------------------------------
    MERGE INTO VALUATION_DB.CONSUMPTION.DIM_COMPANY d
    USING VALUATION_DB.CURATED.SECURITY_MASTER s
       ON d.ticker = s.ticker
    WHEN MATCHED THEN UPDATE SET
         company_name = s.company_name, sector_theme = s.sector_theme,
         primary_cik = s.primary_cik, sec_registrant_title = s.sec_registrant_title,
         _updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
         (ticker, company_name, sector_theme, primary_cik, sec_registrant_title, _updated_at)
    VALUES (s.ticker, s.company_name, s.sector_theme, s.primary_cik, s.sec_registrant_title,
            CURRENT_TIMESTAMP());

    -- DIM_DATE trading-day flag derived from observed market data
    UPDATE VALUATION_DB.CONSUMPTION.DIM_DATE SET is_trading_day = FALSE WHERE is_trading_day;
    UPDATE VALUATION_DB.CONSUMPTION.DIM_DATE d
       SET is_trading_day = TRUE
      FROM (SELECT DISTINCT trade_date FROM VALUATION_DB.CURATED.MARKET_PRICES_DAILY) t
     WHERE d.calendar_date = t.trade_date;

    -- ------------------------------------------------------------------------
    -- FCT_DAILY_PRICES - rolling technical metrics
    -- ------------------------------------------------------------------------
    INSERT OVERWRITE INTO VALUATION_DB.CONSUMPTION.FCT_DAILY_PRICES
    WITH p AS (
        SELECT m.*, c.company_key,
               m.adj_close_price
                 / LAG(m.adj_close_price) OVER (PARTITION BY m.ticker ORDER BY m.trade_date) - 1
                 AS daily_return
        FROM VALUATION_DB.CURATED.MARKET_PRICES_DAILY m
        JOIN VALUATION_DB.CONSUMPTION.DIM_COMPANY c ON c.ticker = m.ticker
    )
    SELECT TO_NUMBER(TO_CHAR(trade_date, 'YYYYMMDD')),
           company_key, trade_date, ticker,
           open_price, high_price, low_price, close_price, adj_close_price, volume,
           close_price * volume,
           daily_return,
           IFF(COUNT(*) OVER (PARTITION BY ticker ORDER BY trade_date
                              ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) = 30,
               AVG(close_price) OVER (PARTITION BY ticker ORDER BY trade_date
                                      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW), NULL),
           IFF(COUNT(*) OVER (PARTITION BY ticker ORDER BY trade_date
                              ROWS BETWEEN 199 PRECEDING AND CURRENT ROW) = 200,
               AVG(close_price) OVER (PARTITION BY ticker ORDER BY trade_date
                                      ROWS BETWEEN 199 PRECEDING AND CURRENT ROW), NULL),
           STDDEV_SAMP(daily_return) OVER (PARTITION BY ticker ORDER BY trade_date
                                           ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) * SQRT(252),
           MAX(high_price) OVER (PARTITION BY ticker ORDER BY trade_date
                                 ROWS BETWEEN 251 PRECEDING AND CURRENT ROW),
           MIN(low_price)  OVER (PARTITION BY ticker ORDER BY trade_date
                                 ROWS BETWEEN 251 PRECEDING AND CURRENT ROW)
    FROM p
    ORDER BY trade_date, ticker;    -- sort-on-load = natural clustering by date, for free

    -- ------------------------------------------------------------------------
    -- FCT_FUNDAMENTALS_QUARTERLY
    -- ------------------------------------------------------------------------
    INSERT OVERWRITE INTO VALUATION_DB.CONSUMPTION.FCT_FUNDAMENTALS_QUARTERLY
    WITH filing_split_factor AS (
        -- product of all splits after each filing date: EXP(SUM(LN(x))) = PRODUCT(x)
        SELECT f.ticker, f.filed_date,
               COALESCE(EXP(SUM(LN(sp.split_ratio))), 1) AS split_factor
        FROM (SELECT DISTINCT ticker, filed_date FROM VALUATION_DB.CURATED.SEC_FUNDAMENTALS_STD) f
        LEFT JOIN VALUATION_DB.CURATED.STOCK_SPLITS sp
               ON sp.ticker = f.ticker AND sp.split_date > f.filed_date
        GROUP BY f.ticker, f.filed_date
    ),
    adj AS (
        SELECT s.ticker, s.metric, s.value_kind, s.period_start, s.period_end, s.period_days,
               s.filed_date,
               IFF(s.is_per_share, s.value / ff.split_factor, s.value) AS value_adj
        FROM VALUATION_DB.CURATED.SEC_FUNDAMENTALS_STD s
        JOIN filing_split_factor ff
          ON ff.ticker = s.ticker AND ff.filed_date = s.filed_date
    ),
    -- Rule 2: cumulative chains (same period_start) -> discrete quarter candidates
    chain AS (
        SELECT ticker, metric, period_start, period_end, value_adj, filed_date,
               LAG(period_end)  OVER (PARTITION BY ticker, metric, period_start ORDER BY period_end) AS prev_end,
               LAG(value_adj)   OVER (PARTITION BY ticker, metric, period_start ORDER BY period_end) AS prev_value,
               LAG(filed_date)  OVER (PARTITION BY ticker, metric, period_start ORDER BY period_end) AS prev_filed
        FROM adj
        WHERE value_kind = 'DURATION' AND period_days BETWEEN 80 AND 375
    ),
    quarter_candidates AS (
        SELECT ticker, metric, period_end,
               IFF(prev_end IS NULL, value_adj, value_adj - prev_value)           AS q_value,
               DATEDIFF('day', COALESCE(prev_end, period_start), period_end)      AS q_days,
               GREATEST(filed_date, COALESCE(prev_filed, filed_date))             AS known_date,
               prev_end IS NULL                                                   AS is_direct
        FROM chain
    ),
    quarters AS (
        SELECT ticker, metric, period_end, q_value, known_date
        FROM quarter_candidates
        WHERE q_days BETWEEN 80 AND 120           -- 13-week and 16-week fiscal quarters
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ticker, metric, period_end
                                   ORDER BY is_direct DESC, known_date ASC) = 1
    ),
    flows AS (
        SELECT ticker, period_end AS fiscal_quarter_end,
               MAX(IFF(metric = 'revenue',             q_value, NULL)) AS revenue_q,
               MAX(IFF(metric = 'net_income',          q_value, NULL)) AS net_income_q,
               MAX(IFF(metric = 'eps_diluted',         q_value, NULL)) AS eps_diluted_q,
               MAX(IFF(metric = 'operating_cash_flow', q_value, NULL)) AS operating_cash_flow_q,
               MAX(known_date)                                         AS known_date
        FROM quarters
        GROUP BY ticker, period_end
    ),
    stocks AS (
        SELECT ticker, period_end,
               MAX(IFF(metric = 'total_assets',           value_adj, NULL)) AS total_assets,
               MAX(IFF(metric = 'total_liabilities',      value_adj, NULL)) AS total_liabilities,
               MAX(IFF(metric = 'liabilities_and_equity', value_adj, NULL)) AS liabilities_and_equity,
               MAX(IFF(metric = 'total_equity',           value_adj, NULL)) AS total_equity,
               MAX(IFF(metric = 'total_equity_incl_nci',  value_adj, NULL)) AS total_equity_incl_nci,
               MAX(IFF(metric = 'long_term_debt',         value_adj, NULL)) AS long_term_debt,
               MAX(IFF(metric = 'short_term_borrowings',  value_adj, NULL)) AS short_term_borrowings,
               MAX(IFF(metric = 'cash_and_equivalents',   value_adj, NULL)) AS cash_and_equivalents,
               MAX(filed_date)                                              AS bs_known_date
        FROM adj
        WHERE value_kind = 'INSTANT'
        GROUP BY ticker, period_end
    ),
    combined AS (
        SELECT f.*,
               s.total_assets,
               COALESCE(s.total_liabilities, s.liabilities_and_equity - s.total_equity_incl_nci) AS total_liabilities,
               s.total_liabilities IS NULL AND s.liabilities_and_equity IS NOT NULL               AS is_liabilities_derived,
               s.total_equity,
               s.long_term_debt + COALESCE(s.short_term_borrowings, 0)                         AS total_debt,
               s.cash_and_equivalents,
               GREATEST(f.known_date, COALESCE(s.bs_known_date, f.known_date))                  AS q_known_date,
               COUNT(f.eps_diluted_q) OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)  AS n_eps,
               COUNT(f.revenue_q)     OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)  AS n_rev,
               COUNT(f.net_income_q)  OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)  AS n_ni,
               COUNT(f.operating_cash_flow_q) OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS n_ocf,
               DATEDIFF('day', LAG(f.fiscal_quarter_end, 3) OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end),
                        f.fiscal_quarter_end) AS span_4q_days,
               SUM(f.revenue_q)             OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS revenue_ttm_raw,
               SUM(f.net_income_q)          OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS net_income_ttm_raw,
               SUM(f.eps_diluted_q)         OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS eps_ttm_raw,
               SUM(f.operating_cash_flow_q) OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS ocf_ttm_raw,
               MAX(f.known_date)            OVER (PARTITION BY f.ticker ORDER BY f.fiscal_quarter_end ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS ttm_known_date
        FROM flows f
        LEFT JOIN stocks s
               ON s.ticker = f.ticker AND s.period_end = f.fiscal_quarter_end
    ),
    ttm AS (
        SELECT c.*,
               span_4q_days BETWEEN 250 AND 300 AS contiguous,
               IFF(contiguous AND n_rev = 4, revenue_ttm_raw,    NULL) AS revenue_ttm,
               IFF(contiguous AND n_ni  = 4, net_income_ttm_raw, NULL) AS net_income_ttm,
               IFF(contiguous AND n_eps = 4, eps_ttm_raw,        NULL) AS eps_diluted_ttm,
               IFF(contiguous AND n_ocf = 4, ocf_ttm_raw,        NULL) AS operating_cash_flow_ttm
        FROM combined c
    )
    SELECT d.company_key, t.ticker, t.fiscal_quarter_end,
           GREATEST(t.q_known_date, t.ttm_known_date)                        AS known_date,
           t.revenue_q, t.net_income_q, t.eps_diluted_q, t.operating_cash_flow_q,
           t.revenue_ttm, t.net_income_ttm, t.eps_diluted_ttm, t.operating_cash_flow_ttm,
           t.total_assets, t.total_liabilities, t.is_liabilities_derived, t.total_equity,
           t.total_debt, t.cash_and_equivalents,
           -- leverage ratios are not meaningful with negative equity (e.g. MCD, SBUX buy-backs)
           IFF(t.total_equity > 0, t.total_debt / t.total_equity, NULL)        AS debt_to_equity,
           IFF(t.total_equity > 0, t.total_liabilities / t.total_equity, NULL) AS liabilities_to_equity,
           t.net_income_ttm / NULLIF(t.revenue_ttm, 0)                         AS net_margin_ttm,
           IFF(t.net_income_ttm > 0, t.operating_cash_flow_ttm / t.net_income_ttm, NULL) AS cash_conversion_ttm,
           t.revenue_ttm / NULLIF(LAG(t.revenue_ttm, 4) OVER (PARTITION BY t.ticker ORDER BY t.fiscal_quarter_end), 0) - 1
                                                                               AS revenue_growth_yoy,
           (t.eps_diluted_ttm - LAG(t.eps_diluted_ttm, 4) OVER (PARTITION BY t.ticker ORDER BY t.fiscal_quarter_end))
             / NULLIF(ABS(LAG(t.eps_diluted_ttm, 4) OVER (PARTITION BY t.ticker ORDER BY t.fiscal_quarter_end)), 0)
                                                                               AS eps_growth_yoy,
           t.eps_diluted_ttm IS NOT NULL                                       AS has_full_ttm
    FROM ttm t
    JOIN VALUATION_DB.CONSUMPTION.DIM_COMPANY d ON d.ticker = t.ticker
    ORDER BY t.ticker, t.fiscal_quarter_end;

    -- ------------------------------------------------------------------------
    -- FCT_DAILY_VALUATION - ASOF JOIN: for each trading day, the latest quarter
    -- whose numbers were already public (filed strictly before that day).
    -- ------------------------------------------------------------------------
    INSERT OVERWRITE INTO VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION
    SELECT p.date_key, p.company_key, p.trade_date, p.ticker, p.close_price,
           f.fiscal_quarter_end,
           f.known_date,
           DATEDIFF('day', f.known_date, p.trade_date),
           f.eps_diluted_ttm,
           IFF(f.eps_diluted_ttm > 0, p.close_price / f.eps_diluted_ttm, NULL),   -- P/E
           f.eps_diluted_ttm / NULLIF(p.close_price, 0),                          -- earnings yield
           f.debt_to_equity,
           f.liabilities_to_equity,
           f.net_margin_ttm,
           f.revenue_growth_yoy,
           f.eps_diluted_ttm <= 0,
           DATEDIFF('day', f.known_date, p.trade_date) > 135
    FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_PRICES p
    ASOF JOIN (SELECT * FROM VALUATION_DB.CONSUMPTION.FCT_FUNDAMENTALS_QUARTERLY
               WHERE has_full_ttm) f
         MATCH_CONDITION (p.trade_date > f.known_date)
         ON p.company_key = f.company_key
    ORDER BY p.trade_date, p.ticker;

    COMMIT;

    SELECT COUNT(*) INTO :n_prices    FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_PRICES;
    SELECT COUNT(*) INTO :n_quarters  FROM VALUATION_DB.CONSUMPTION.FCT_FUNDAMENTALS_QUARTERLY;
    SELECT COUNT(*) INTO :n_valuation FROM VALUATION_DB.CONSUMPTION.FCT_DAILY_VALUATION;

    result := OBJECT_CONSTRUCT('fct_daily_prices', n_prices,
                               'fct_fundamentals_quarterly', n_quarters,
                               'fct_daily_valuation', n_valuation);
    INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
        SELECT 'SP_BUILD_CONSUMPTION', 'SUCCEEDED', :result, :started_at;
    RETURN result;

EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        INSERT INTO VALUATION_DB.OPS.PIPELINE_RUN_LOG (step_name, status, details, started_at)
            SELECT 'SP_BUILD_CONSUMPTION', 'FAILED',
                   OBJECT_CONSTRUCT('sqlcode', :SQLCODE, 'sqlerrm', :SQLERRM, 'sqlstate', :SQLSTATE),
                   :started_at;
        RAISE;
END;
$$;
