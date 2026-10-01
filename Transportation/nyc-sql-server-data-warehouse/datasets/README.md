# Datasets

| Folder | Source system(s) | Content | In Git? |
|---|---|---|---|
| `source_tlc/` | yellow, green, fhv, fhvhv | Monthly trip record **Parquet** files from the [NYC TLC Trip Record Data](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page) page | No (too large, see `.gitignore`) |
| `source_reference/` | tlc | `taxi_zone_lookup.csv` (TLC) and `tlc_code_values.csv` (code values transcribed from the TLC data dictionaries) | Yes |
| `source_weather/` | openmeteo | Hourly weather for Central Park pulled from the [Open-Meteo Historical Weather API](https://open-meteo.com/en/docs/historical-weather-api) by `scripts/extract/extract_sources.py` | Yes (small, makes runs reproducible offline) |

## Getting the trip files

Download the four January 2025 files into `source_tlc/`:

```
yellow_tripdata_2025-01.parquet
green_tripdata_2025-01.parquet
fhv_tripdata_2025-01.parquet
fhvhv_tripdata_2025-01.parquet
```

They are published at `https://d37ci6vzurychx.cloudfront.net/trip-data/<file name>`.

## Licences / attribution

- TLC trip records and taxi zones: NYC Open Data, published by the NYC Taxi & Limousine Commission.
- Weather data: [Open-Meteo](https://open-meteo.com/), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
