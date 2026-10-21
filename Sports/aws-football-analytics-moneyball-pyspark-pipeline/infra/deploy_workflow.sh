#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Creates the Glue Workflow that chains the three pipelines + failure alerting.
#
#   start trigger  ──►  pl_01_statsbomb_bronze_to_silver ─┐
#   (cron/on-demand) ►  pl_02_transfermarkt_bronze_to_silver ─┤ ALL SUCCEEDED
#                                                             └──► pl_03_silver_to_gold_moneyball ──► gold crawler
#
# Prerequisites: the three Glue jobs already exist (saved from the notebooks)
# and the gold crawler exists if CREATE_CRAWLER_STEP=true.
#
# Usage:  BUCKET=football-analytics-moneyball-123456789012 ALERT_EMAIL=me@example.com ./infra/deploy_workflow.sh
# -----------------------------------------------------------------------------
set -euo pipefail

: "${BUCKET:?Set BUCKET to your project bucket name}"
REGION="${AWS_REGION:-eu-west-1}"
WORKFLOW="wf_football_moneyball"
JOB1="pl_01_statsbomb_bronze_to_silver"
JOB2="pl_02_transfermarkt_bronze_to_silver"
JOB3="pl_03_silver_to_gold_moneyball"
CRAWLER="crawler_football_gold"
CREATE_CRAWLER_STEP="${CREATE_CRAWLER_STEP:-true}"
SCHEDULE="${SCHEDULE:-cron(0 6 ? * MON *)}"   # every Monday 06:00 UTC

echo "1/5  Workflow"
aws glue create-workflow --region "$REGION" --name "$WORKFLOW" \
  --description "Football Moneyball: bronze -> silver (x2, parallel) -> gold" \
  --max-concurrent-runs 1

echo "2/5  Start trigger: launches PL-01 and PL-02 in parallel"
aws glue create-trigger --region "$REGION" --workflow-name "$WORKFLOW" \
  --name "trg_start_${WORKFLOW}" --type SCHEDULED --schedule "$SCHEDULE" \
  --actions "[{\"JobName\":\"$JOB1\",\"Arguments\":{\"--BUCKET\":\"$BUCKET\"}},
              {\"JobName\":\"$JOB2\",\"Arguments\":{\"--BUCKET\":\"$BUCKET\"}}]" \
  --start-on-creation

echo "3/5  Conditional trigger: PL-03 only when BOTH silver jobs SUCCEEDED"
aws glue create-trigger --region "$REGION" --workflow-name "$WORKFLOW" \
  --name "trg_gold_after_silver" --type CONDITIONAL \
  --predicate "{\"Logical\":\"AND\",\"Conditions\":[
      {\"LogicalOperator\":\"EQUALS\",\"JobName\":\"$JOB1\",\"State\":\"SUCCEEDED\"},
      {\"LogicalOperator\":\"EQUALS\",\"JobName\":\"$JOB2\",\"State\":\"SUCCEEDED\"}]}" \
  --actions "[{\"JobName\":\"$JOB3\",\"Arguments\":{\"--BUCKET\":\"$BUCKET\"}}]" \
  --start-on-creation

if [[ "$CREATE_CRAWLER_STEP" == "true" ]]; then
  echo "4/5  Conditional trigger: refresh the gold tables in the Data Catalog"
  aws glue create-trigger --region "$REGION" --workflow-name "$WORKFLOW" \
    --name "trg_crawl_gold" --type CONDITIONAL \
    --predicate "{\"Conditions\":[{\"LogicalOperator\":\"EQUALS\",\"JobName\":\"$JOB3\",\"State\":\"SUCCEEDED\"}]}" \
    --actions "[{\"CrawlerName\":\"$CRAWLER\"}]" \
    --start-on-creation
fi

if [[ -n "${ALERT_EMAIL:-}" ]]; then
  echo "5/5  Failure alerts: EventBridge (Glue job FAILED/TIMEOUT) -> SNS e-mail"
  TOPIC_ARN=$(aws sns create-topic --region "$REGION" --name football-pipeline-alerts --query TopicArn --output text)
  aws sns subscribe --region "$REGION" --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL"
  aws events put-rule --region "$REGION" --name football-glue-job-failed \
    --event-pattern "{\"source\":[\"aws.glue\"],\"detail-type\":[\"Glue Job State Change\"],
                      \"detail\":{\"jobName\":[\"$JOB1\",\"$JOB2\",\"$JOB3\"],\"state\":[\"FAILED\",\"TIMEOUT\"]}}"
  aws events put-targets --region "$REGION" --rule football-glue-job-failed --targets "Id=sns,Arn=$TOPIC_ARN"
  # Allow EventBridge to publish to the topic
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  aws sns set-topic-attributes --region "$REGION" --topic-arn "$TOPIC_ARN" --attribute-name Policy \
    --attribute-value "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
      \"Principal\":{\"Service\":\"events.amazonaws.com\"},\"Action\":\"sns:Publish\",\"Resource\":\"$TOPIC_ARN\",
      \"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$ACCOUNT_ID\"}}}]}"
  echo "     Confirm the subscription e-mail sent to $ALERT_EMAIL"
else
  echo "5/5  Skipped alerts (set ALERT_EMAIL to enable)"
fi

echo "Done. Run it now with:  aws glue start-workflow-run --name $WORKFLOW --region $REGION"
