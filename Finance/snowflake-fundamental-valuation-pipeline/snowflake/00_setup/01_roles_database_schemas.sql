/* =============================================================================
   01 - Roles, database and zone schemas
   -----------------------------------------------------------------------------
   Run as: ACCOUNTADMIN (role creation + account-level grants)

   Zone model (see README "Data architecture"):
     LANDING      - stages, file formats, pipes, raw tables, streams  (TRANSIENT)
     CURATED      - typed, de-duplicated, conformed data              (TRANSIENT)
     CONSUMPTION  - star schema for analytics (gold)                  (PERMANENT)
     ANALYTICS    - dbt marts built on top of CONSUMPTION             (PERMANENT)
     OPS          - stored procedures, tasks, run log, DQ results     (PERMANENT)

   Least-privilege RBAC:
     VALUATION_PIPELINE  - owns every object, runs tasks (service-style role)
     VALUATION_ANALYST   - read-only on CONSUMPTION + ANALYTICS
============================================================================= */
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS VALUATION_PIPELINE COMMENT = 'Owns and runs the fundamental valuation pipeline';
CREATE ROLE IF NOT EXISTS VALUATION_ANALYST  COMMENT = 'Read-only consumer of CONSUMPTION and ANALYTICS';

-- Role hierarchy: custom roles roll up to SYSADMIN so admins keep visibility.
GRANT ROLE VALUATION_ANALYST  TO ROLE VALUATION_PIPELINE;
GRANT ROLE VALUATION_PIPELINE TO ROLE SYSADMIN;
SET my_user = CURRENT_USER();
GRANT ROLE VALUATION_PIPELINE TO USER IDENTIFIER($my_user);

-- Account-level privileges needed by the pipeline role
GRANT CREATE DATABASE    ON ACCOUNT TO ROLE VALUATION_PIPELINE;
GRANT EXECUTE TASK       ON ACCOUNT TO ROLE VALUATION_PIPELINE;   -- run task graphs
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE VALUATION_PIPELINE; -- optional: serverless tasks
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE VALUATION_PIPELINE; -- ACCOUNT_USAGE views for monitoring

USE ROLE VALUATION_PIPELINE;

CREATE DATABASE IF NOT EXISTS VALUATION_DB
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Fundamental valuation pipeline: Yahoo Finance prices + SEC EDGAR fundamentals';

-- TRANSIENT schemas: every table created inside is transient by default
-- (no Fail-safe, max 1 day Time Travel). Both zones are fully reproducible
-- from the immutable files kept in the stages - see README "Table types".
CREATE TRANSIENT SCHEMA IF NOT EXISTS VALUATION_DB.LANDING
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Landing zone: stages, file formats, pipes, raw tables, streams';

CREATE TRANSIENT SCHEMA IF NOT EXISTS VALUATION_DB.CURATED
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Curated zone: typed, cleaned, de-duplicated, conformed data';

-- PERMANENT schemas: what consumers query; protected by Time Travel + Fail-safe.
CREATE SCHEMA IF NOT EXISTS VALUATION_DB.CONSUMPTION
  DATA_RETENTION_TIME_IN_DAYS = 1   -- raise to 7+ on Enterprise edition
  COMMENT = 'Consumption zone: star schema (dimensions + facts) for analytics';

CREATE SCHEMA IF NOT EXISTS VALUATION_DB.ANALYTICS
  COMMENT = 'dbt marts built on top of CONSUMPTION';

CREATE SCHEMA IF NOT EXISTS VALUATION_DB.OPS
  COMMENT = 'Orchestration: stored procedures, tasks, run log, data-quality results';

-- Analyst read access (current + future objects)
USE ROLE ACCOUNTADMIN;
GRANT USAGE ON DATABASE VALUATION_DB TO ROLE VALUATION_ANALYST;
GRANT USAGE ON SCHEMA VALUATION_DB.CONSUMPTION TO ROLE VALUATION_ANALYST;
GRANT USAGE ON SCHEMA VALUATION_DB.ANALYTICS   TO ROLE VALUATION_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA VALUATION_DB.CONSUMPTION TO ROLE VALUATION_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA VALUATION_DB.ANALYTICS   TO ROLE VALUATION_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA VALUATION_DB.ANALYTICS   TO ROLE VALUATION_ANALYST;
