/* =============================================================================
   Register the Snowpark Python procedure OPS.SP_CURATE_SEC_FUNDAMENTALS
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   The Python source lives in its own file (sp_curate_sec_fundamentals.py) so it
   can be linted, unit-tested and code-reviewed like any other Python module.
   Snowflake imports it from a stage at call time.

   Option A: upload the file to the code stage
     Snowsight > Data > Databases > VALUATION_DB > OPS > Stages > STG_CODE >
     "+ Files" > sp_curate_sec_fundamentals.py   (or with SnowSQL/Snowflake CLI:
     PUT file://snowflake/stored_procedures/python/sp_curate_sec_fundamentals.py
         @VALUATION_DB.OPS.STG_CODE AUTO_COMPRESS=FALSE OVERWRITE=TRUE;)

   Option B: import straight from the Git repository stage
     (see 00_setup/04_git_integration_optional.sql) - swap the IMPORTS line.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.OPS;

CREATE OR REPLACE PROCEDURE SP_CURATE_SEC_FUNDAMENTALS(FULL_REBUILD BOOLEAN DEFAULT FALSE)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
IMPORTS = ('@VALUATION_DB.OPS.STG_CODE/sp_curate_sec_fundamentals.py')
-- IMPORTS = ('@VALUATION_DB.OPS.VALUATION_REPO/branches/main/snowflake/stored_procedures/python/sp_curate_sec_fundamentals.py')
HANDLER = 'sp_curate_sec_fundamentals.main'
EXECUTE AS OWNER
COMMENT = 'Snowpark: flatten SEC companyfacts VARIANT -> facts (MERGE) -> standardised metrics';

-- Smoke test (after files are loaded):
--   CALL VALUATION_DB.OPS.SP_CURATE_SEC_FUNDAMENTALS();
--   CALL VALUATION_DB.OPS.SP_CURATE_SEC_FUNDAMENTALS(TRUE);   -- re-parse everything
