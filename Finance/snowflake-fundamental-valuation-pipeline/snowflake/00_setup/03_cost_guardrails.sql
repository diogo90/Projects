/* =============================================================================
   03 - Cost guardrails: resource monitors + budget
   -----------------------------------------------------------------------------
   Run as: ACCOUNTADMIN.  RUN THIS BEFORE ANY DATA IS LOADED.

   Two complementary controls:
   1. RESOURCE MONITORS: hard stop for WAREHOUSE compute. They can SUSPEND
      warehouses when a credit quota is reached. They do NOT cover serverless
      features (Snowpipe, serverless tasks, auto-clustering, search optimisation).
   2. BUDGETS: monitor ALL credit usage, serverless included, and alert
      by e-mail when spend is projected to exceed the limit. Budgets alert but
      do not suspend anything.

   Quota maths for a ~GBP 30 ceiling:
     GBP 30 ~ USD 38. At ~USD 3/credit (Enterprise, on-demand; varies by region)
     that is ~12 credits. Quotas are set below that, at 10 credits/month account-wide.
     The whole pipeline needs well under 1 credit per end-to-end run.
============================================================================= */
USE ROLE ACCOUNTADMIN;

-- 1a. Account-level safety net: suspends EVERY warehouse in the account at 100%.
CREATE OR REPLACE RESOURCE MONITOR RM_ACCOUNT_MONTHLY
  WITH CREDIT_QUOTA = 10
       FREQUENCY = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 50  PERCENT DO NOTIFY
    ON 75  PERCENT DO NOTIFY
    ON 90  PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND            -- let running queries finish, then suspend
    ON 110 PERCENT DO SUSPEND_IMMEDIATE; -- cancel running queries too

ALTER ACCOUNT SET RESOURCE_MONITOR = RM_ACCOUNT_MONTHLY;

-- 1b. Project-level monitor: tighter quota on the pipeline's own warehouses.
CREATE OR REPLACE RESOURCE MONITOR RM_VALUATION_PIPELINE
  WITH CREDIT_QUOTA = 6
       FREQUENCY = MONTHLY
       START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75  PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE WH_INGEST    SET RESOURCE_MONITOR = RM_VALUATION_PIPELINE;
ALTER WAREHOUSE WH_TRANSFORM SET RESOURCE_MONITOR = RM_VALUATION_PIPELINE;
ALTER WAREHOUSE WH_ANALYTICS SET RESOURCE_MONITOR = RM_VALUATION_PIPELINE;

-- Notifications go to account admins who have a VERIFIED e-mail address
-- (Snowsight > your profile > verify e-mail).

-- 2. Account budget: covers serverless spend (Snowpipe, serverless tasks, ...).
--    Equivalent UI: Snowsight > Admin > Cost Management > Budgets > Set up account budget.
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS NI_BUDGET_EMAIL
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('your.verified.email@example.com');   -- <-- change me

CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!ACTIVATE();
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_SPENDING_LIMIT(12);     -- credits / month
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_EMAIL_NOTIFICATIONS(
  'NI_BUDGET_EMAIL', 'your.verified.email@example.com');          -- <-- change me

-- 3. Session-level habits that also cap spend
ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;   -- no query may run > 1 hour

-- Verify
SHOW RESOURCE MONITORS;
SHOW WAREHOUSES LIKE 'WH_%';
