# Raw data (files to upload to the Snowflake stages)

| Local path | Upload to stage path | Loaded by |
|---|---|---|
| `dataset1/backfill/prices_backfill_<start>_<end>.csv` | `@VALUATION_DB.LANDING.STG_MARKET_DATA/prices/backfill/` | `PIPE_MARKET_PRICES` |
| `dataset1/daily/prices_YYYY-MM-DD.csv` | `@VALUATION_DB.LANDING.STG_MARKET_DATA/prices/daily/` | `PIPE_MARKET_PRICES` (incremental runs) |
| `dataset1/reference/stock_splits.csv` | `@VALUATION_DB.LANDING.STG_MARKET_DATA/splits/` | `SP_LOAD_REFERENCE_DATA` |
| `../../config/ticker_universe.csv` | `@VALUATION_DB.LANDING.STG_MARKET_DATA/universe/` | `SP_LOAD_REFERENCE_DATA` |
| `dataset2/companyfacts/CIK##########.json.gz` (51) | `@VALUATION_DB.LANDING.STG_SEC_EDGAR/companyfacts/` | `PIPE_SEC_COMPANYFACTS` |
| `dataset2/reference/company_tickers.json.gz` | `@VALUATION_DB.LANDING.STG_SEC_EDGAR/ticker_map/` | `SP_LOAD_REFERENCE_DATA` |

## Dataset 1: Yahoo Finance (via `yfinance`), generated locally, not in Git
Yahoo's terms do not allow redistributing its data, so `dataset1/` is git-ignored. Run `ingestion/extract_market_prices.py` to create it (commands in [`dataset1/README.md`](dataset1/README.md)).
- Columns: `ticker, trade_date, open, high, low, close, adj_close, volume, dividends, stock_splits, source, extracted_at_utc`
- `close` is split-adjusted (not dividend-adjusted); `adj_close` is split- and dividend-adjusted.
- Reference run used for the documentation: backfill 2021-10-01 to 2026-09-30 (1,254 trading days x 50 tickers = 62,700 rows), plus one delta file per trading day from 2026-10-01 to 2026-10-13, extracted on 2026-10-14.

## Dataset 2: SEC EDGAR companyfacts (included, public domain)
- One JSON document per SEC registrant (CIK), as published in the SEC bulk archive `companyfacts.zip`, gzip-compressed with unchanged bytes. Snowflake reads `.gz` natively.
- 51 files: 50 companies + the predecessor registrant of XOM (CIK 0000034088), which holds Exxon's history before its 2026 holding-company reorganisation.
- `company_tickers.json.gz`: the SEC's ticker -> CIK map, used to validate the universe.
- Extracted with `ingestion/extract_sec_companyfacts.py`, which streams only the needed members out of the 1.4 GB archive without unzipping it.
