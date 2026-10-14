"""
OPS.SP_CURATE_SEC_FUNDAMENTALS - Snowpark Python stored procedure.

LANDING.RAW_SEC_COMPANYFACTS (one VARIANT document per company)
    -> CURATED.SEC_FINANCIAL_FACTS   (every XBRL fact, long/narrow, incremental MERGE)
    -> CURATED.SEC_FUNDAMENTALS_STD  (standard metrics, first-reported values, full rebuild)

Why Snowpark (Python) here and SQL elsewhere?
  The SEC document is a 4-level nested structure
      facts -> taxonomy -> concept -> units -> [fact, fact, ...]
  and the standardisation rules (concept priority, first-reported value,
  instant vs duration validity) are easier to read, unit-test and extend as
  composable DataFrame steps than as one long SQL statement. Snowpark compiles
  these DataFrames to SQL, so all the work still runs inside the warehouse:
  no data leaves Snowflake and nothing is pulled into Python memory.

Incremental semantics
  - Facts: the MERGE source is built on top of the STREAM, so the stream offset
    advances only if the MERGE commits (single atomic statement). A company
    document re-delivered with more history only inserts the facts that are new.
  - Standardised metrics: rebuilt in full on every call. That is cheap at this
    scale, and it means a change to REF_XBRL_CONCEPT_MAP takes effect right away,
    without reprocessing raw documents.

Handler: sp_curate_sec_fundamentals.main
"""
from __future__ import annotations

import json
from datetime import datetime, timezone

from snowflake.snowpark import DataFrame, Session
from snowflake.snowpark import functions as F
from snowflake.snowpark.types import DateType, DecimalType, IntegerType, StringType
from snowflake.snowpark.window import Window

DB = "VALUATION_DB"
RAW_TABLE = f"{DB}.LANDING.RAW_SEC_COMPANYFACTS"
RAW_STREAM = f"{DB}.LANDING.STRM_RAW_SEC_COMPANYFACTS"
FACTS_TABLE = f"{DB}.CURATED.SEC_FINANCIAL_FACTS"
STD_TABLE = f"{DB}.CURATED.SEC_FUNDAMENTALS_STD"
CONCEPT_MAP = f"{DB}.CURATED.REF_XBRL_CONCEPT_MAP"
ENTITY_MAP = f"{DB}.CURATED.SEC_ENTITY_MAP"
RUN_LOG = f"{DB}.OPS.PIPELINE_RUN_LOG"

KEEP_TAXONOMIES = ["us-gaap", "dei"]               # srt/ifrs/invest are not used downstream
REPORTING_FORMS = ["10-K", "10-Q", "10-K/A", "10-Q/A"]
FACT_KEY = ["CIK", "TAXONOMY", "CONCEPT", "UNIT", "PERIOD_START", "PERIOD_END", "ACCESSION_NO"]


# --------------------------------------------------------------------------- #
# Transformations (pure DataFrame -> DataFrame, unit-testable)
# --------------------------------------------------------------------------- #
def latest_document_per_cik(docs: DataFrame) -> DataFrame:
    """If several snapshots of the same company arrive in one batch, keep the newest."""
    w = Window.partition_by("CIK").order_by(F.col("_LOADED_AT").desc(), F.col("_SOURCE_FILE").desc())
    return docs.with_column("_RN", F.row_number().over(w)).filter(F.col("_RN") == 1).drop("_RN")


def flatten_companyfacts(docs: DataFrame) -> DataFrame:
    """facts -> taxonomy -> concept -> unit -> fact[]  ==>  one row per fact."""
    taxonomies = (
        docs.join_table_function("flatten", input=F.col("PAYLOAD")["facts"])
        .select("CIK", "_SOURCE_FILE",
                F.col("KEY").alias("TAXONOMY"), F.col("VALUE").alias("TAXONOMY_OBJ"))
        .filter(F.col("TAXONOMY").isin(KEEP_TAXONOMIES))
    )
    concepts = (
        taxonomies.join_table_function("flatten", input=F.col("TAXONOMY_OBJ"))
        .select("CIK", "_SOURCE_FILE", "TAXONOMY",
                F.col("KEY").alias("CONCEPT"), F.col("VALUE")["units"].alias("UNITS_OBJ"))
    )
    units = (
        concepts.join_table_function("flatten", input=F.col("UNITS_OBJ"))
        .select("CIK", "_SOURCE_FILE", "TAXONOMY", "CONCEPT",
                F.col("KEY").alias("UNIT"), F.col("VALUE").alias("FACT_ARRAY"))
    )
    facts = units.join_table_function("flatten", input=F.col("FACT_ARRAY"))

    f = F.col("VALUE")
    return facts.select(
        F.col("CIK").cast(DecimalType(10, 0)).alias("CIK"),
        F.col("TAXONOMY"),
        F.col("CONCEPT"),
        F.col("UNIT"),
        F.to_date(f["start"].cast(StringType())).alias("PERIOD_START"),
        F.to_date(f["end"].cast(StringType())).alias("PERIOD_END"),
        f["val"].cast(DecimalType(38, 6)).alias("VALUE"),
        f["accn"].cast(StringType()).alias("ACCESSION_NO"),
        f["form"].cast(StringType()).alias("FORM"),
        F.to_date(f["filed"].cast(StringType())).alias("FILED_DATE"),
        f["fy"].cast(IntegerType()).alias("FISCAL_YEAR"),
        f["fp"].cast(StringType()).alias("FISCAL_PERIOD"),
        f["frame"].cast(StringType()).alias("FRAME"),
        F.col("_SOURCE_FILE"),
    ).filter(F.col("VALUE").is_not_null() & F.col("PERIOD_END").is_not_null())


def add_fact_id(facts: DataFrame) -> DataFrame:
    """Deterministic surrogate key; NULL-safe because PERIOD_START is NULL for instant facts."""
    parts = [F.coalesce(F.col(c).cast(StringType()), F.lit("")) for c in FACT_KEY]
    return facts.with_column("FACT_ID", F.sha2(F.concat_ws(F.lit("|"), *parts), 256))


def dedupe(df: DataFrame, keys: list[str], order_by: list) -> DataFrame:
    w = Window.partition_by(*keys).order_by(*order_by)
    return df.with_column("_RN", F.row_number().over(w)).filter(F.col("_RN") == 1).drop("_RN")


def standardise(facts: DataFrame, concept_map: DataFrame, entity_map: DataFrame) -> DataFrame:
    """Map XBRL concepts to standard metrics, keeping one value per ticker x metric x period."""
    mapped = (
        facts.filter(F.col("FORM").isin(REPORTING_FORMS))
        .join(concept_map, on=["TAXONOMY", "CONCEPT", "UNIT"])          # inner join = only mapped concepts
        .join(entity_map.select("CIK", "TICKER"), on=["CIK"])           # CIK -> ticker (1 ticker : n CIKs)
        .with_column("PERIOD_DAYS", F.datediff("day", F.col("PERIOD_START"), F.col("PERIOD_END")))
        # A flow (duration) needs a start date; a stock (instant) must not have one.
        .filter(((F.col("VALUE_KIND") == "DURATION") & F.col("PERIOD_START").is_not_null())
                | ((F.col("VALUE_KIND") == "INSTANT") & F.col("PERIOD_START").is_null()))
    )
    # 1. FIRST-REPORTED value per concept and period, across all CIKs of the ticker.
    #    Later filings restate prior periods; using the first value is what the
    #    market actually knew on that date (avoids look-ahead bias in backtests).
    first_reported = dedupe(
        mapped,
        keys=["TICKER", "CONCEPT", "PERIOD_START", "PERIOD_END"],
        order_by=[F.col("FILED_DATE").asc(), F.col("ACCESSION_NO").asc()],
    )
    # 2. Highest-priority concept wins when a company reports several variants.
    best = dedupe(
        first_reported,
        keys=["TICKER", "METRIC", "PERIOD_START", "PERIOD_END"],
        order_by=[F.col("PRIORITY").asc()],
    )
    return best.select(
        "TICKER", "CIK", "METRIC", "VALUE_KIND", "IS_PER_SHARE", "PERIOD_START", "PERIOD_END",
        "PERIOD_DAYS", "VALUE",
        F.col("CONCEPT").alias("SOURCE_CONCEPT"),
        F.col("PRIORITY").alias("CONCEPT_PRIORITY"),
        "ACCESSION_NO", "FORM", "FILED_DATE", "FISCAL_YEAR", "FISCAL_PERIOD",
        F.current_timestamp().alias("_BUILT_AT"),
    )


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #
def merge_new_facts(session: Session, source_docs: DataFrame) -> dict:
    src = dedupe(
        add_fact_id(flatten_companyfacts(latest_document_per_cik(source_docs))),
        keys=["FACT_ID"],
        order_by=[F.col("FILED_DATE").desc()],
    ).with_column("_LOADED_AT", F.current_timestamp())

    target = session.table(FACTS_TABLE)
    cols = [c for c in src.columns]
    result = target.merge(
        src,
        target["FACT_ID"] == src["FACT_ID"],
        [
            # Same filing, same period, different value: SEC corrected the dataset.
            F.when_matched(target["VALUE"] != src["VALUE"]).update(
                {"VALUE": src["VALUE"], "_SOURCE_FILE": src["_SOURCE_FILE"], "_LOADED_AT": src["_LOADED_AT"]}
            ),
            F.when_not_matched().insert({c: src[c] for c in cols}),
        ],
    )
    return {"facts_inserted": result.rows_inserted, "facts_updated": result.rows_updated}


def log(session: Session, status: str, started_at: datetime, details: dict) -> None:
    session.sql(
        f"INSERT INTO {RUN_LOG} (step_name, status, details, started_at) "
        "SELECT 'SP_CURATE_SEC_FUNDAMENTALS', ?, PARSE_JSON(?), ?::TIMESTAMP_LTZ",
        params=[status, json.dumps(details, default=str), started_at.isoformat()],
    ).collect()


def main(session: Session, full_rebuild: bool = False) -> dict:
    """
    full_rebuild = FALSE (default): parse only documents waiting in the stream.
    full_rebuild = TRUE: re-parse every raw document (e.g. after adding a taxonomy),
                         the stream is left untouched.
    """
    started_at = datetime.now(timezone.utc)
    details: dict = {"full_rebuild": full_rebuild}
    try:
        if full_rebuild:
            details.update(merge_new_facts(session, session.table(RAW_TABLE)))
        elif session.sql(f"SELECT SYSTEM$STREAM_HAS_DATA('{RAW_STREAM}')").collect()[0][0]:
            docs = session.table(RAW_STREAM).filter(F.col("METADATA$ACTION") == "INSERT")
            details.update(merge_new_facts(session, docs))
        else:
            details["facts"] = "stream empty - no new documents"

        std = standardise(
            session.table(FACTS_TABLE), session.table(CONCEPT_MAP), session.table(ENTITY_MAP)
        )
        # mode="truncate" keeps the table definition (TRANSIENT, comments, types)
        # instead of CREATE OR REPLACE, so the table is never dropped mid-flight.
        std.write.save_as_table(STD_TABLE, mode="truncate", column_order="name")
        details["std_rows"] = session.table(STD_TABLE).count()
        details["std_tickers"] = session.table(STD_TABLE).select("TICKER").distinct().count()

        log(session, "SUCCEEDED", started_at, details)
        return details
    except Exception as exc:  # log then re-raise so the task is marked FAILED
        details["error"] = str(exc)[:2000]
        log(session, "FAILED", started_at, details)
        raise
