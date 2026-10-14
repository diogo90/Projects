# Dataset 1: Yahoo Finance market data (generate locally)

The files for this folder are **not included in the repository**: Yahoo's terms do not allow redistributing its data. Generate them with the extraction script (about a minute):

```bash
pip install -r requirements.txt
python ingestion/extract_market_prices.py backfill --start 2021-10-01 --end 2026-09-30
python ingestion/extract_market_prices.py delta    --start 2026-10-01 --end 2026-10-13
python ingestion/extract_market_prices.py splits   --start 2010-01-01
```

Resulting layout:

```
dataset1/
├── backfill/prices_backfill_<start>_<end>.csv   # initial historical load
├── daily/prices_YYYY-MM-DD.csv                  # one delta file per trading day (incremental runs)
└── reference/stock_splits.csv                   # full split history (corporate actions)
```

Any date range works. Choose a recent 5-year window for the backfill and the trading days that follow it for the delta files. Columns: `ticker, trade_date, open, high, low, close, adj_close, volume, dividends, stock_splits, source, extracted_at_utc`.
