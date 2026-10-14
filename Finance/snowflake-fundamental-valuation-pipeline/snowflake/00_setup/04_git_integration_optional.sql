/* =============================================================================
   04 - (Optional) Deploy straight from GitHub with a Snowflake Git repository
   -----------------------------------------------------------------------------
   Run as: ACCOUNTADMIN (API integration) then VALUATION_PIPELINE

   With this, GitHub becomes the single source of truth: Snowflake fetches the
   repo, SQL scripts run with EXECUTE IMMEDIATE FROM, the Snowpark procedure
   imports its .py file from the repo, and the dbt project is created from
   the repo's dbt/ folder. No copy-pasting into worksheets.
   For a public repository no secret is needed.
============================================================================= */
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE API INTEGRATION GIT_API_INTEGRATION
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/<your-github-user>')   -- <-- change me
  ENABLED = TRUE;

GRANT USAGE ON INTEGRATION GIT_API_INTEGRATION TO ROLE VALUATION_PIPELINE;

USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE OR REPLACE GIT REPOSITORY VALUATION_DB.OPS.VALUATION_REPO
  API_INTEGRATION = GIT_API_INTEGRATION
  ORIGIN = 'https://github.com/<your-github-user>/Snowflake-Fundamental-Valuation-Pipeline.git';

ALTER GIT REPOSITORY VALUATION_DB.OPS.VALUATION_REPO FETCH;   -- pull latest commits
LIST @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/;

-- Example: deploy the whole project from Git in dependency order
-- (01-03 in 00_setup need ACCOUNTADMIN and are run once by hand).
/*
EXECUTE IMMEDIATE FROM @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/01_landing/01_file_formats_and_stages.sql;
EXECUTE IMMEDIATE FROM @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/01_landing/02_raw_tables.sql;
EXECUTE IMMEDIATE FROM @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/01_landing/03_pipes_and_streams.sql;
EXECUTE IMMEDIATE FROM @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/02_curated/01_reference_config.sql;
EXECUTE IMMEDIATE FROM @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/02_curated/02_curated_tables.sql;
EXECUTE IMMEDIATE FROM @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/03_consumption/01_star_schema.sql;
EXECUTE IMMEDIATE FROM @VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/04_orchestration/01_ops_tables.sql;
-- ... stored procedures, then 04_orchestration/02_task_graph.sql
*/
