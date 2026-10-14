/* =============================================================================
   dbt Projects on Snowflake - deploy and run the dbt project in dbt/
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   dbt runs INSIDE Snowflake (no dbt Cloud, no local install, no credentials).
   The project object is versioned: each deploy creates a new version and
   tasks always execute the live version.

   Deploy options (pick one)
   A. Snowsight Workspaces (UI): Projects > Workspaces > Create > From Git
      repository (or upload the dbt/fundamental_valuation folder) > open
      dbt_project.yml > "Deploy" > name it FUNDAMENTAL_VALUATION_DBT in
      VALUATION_DB.OPS.
   B. SQL from the Git repository stage (00_setup/04_git_integration_optional.sql):
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

ALTER GIT REPOSITORY VALUATION_DB.OPS.VALUATION_REPO FETCH;

CREATE OR REPLACE DBT PROJECT VALUATION_DB.OPS.FUNDAMENTAL_VALUATION_DBT
  FROM '@VALUATION_DB.OPS.VALUATION_REPO/branches/main/dbt/fundamental_valuation'
  DEFAULT_TARGET = 'prod'
  COMMENT = 'Analytics marts on top of the CONSUMPTION star schema';

-- C. Snowflake CLI from a terminal (CI/CD friendly):
--    snow dbt deploy FUNDAMENTAL_VALUATION_DBT --source dbt/fundamental_valuation \
--        --database VALUATION_DB --schema OPS

-- Run on demand (also the last step of the task graph: TSK_50_DBT_BUILD)
EXECUTE DBT PROJECT VALUATION_DB.OPS.FUNDAMENTAL_VALUATION_DBT ARGS = 'build --target prod';

-- Inspect the results
SELECT * FROM VALUATION_DB.ANALYTICS.MART_VALUATION_SNAPSHOT ORDER BY pe_percentile_3y;
GRANT SELECT ON ALL TABLES IN SCHEMA VALUATION_DB.ANALYTICS TO ROLE VALUATION_ANALYST;
