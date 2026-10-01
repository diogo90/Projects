/*
===============================================================================
DDL Script: ETL Control Objects (schema 'etl')
===============================================================================
Script Purpose:
    Creates the objects that make the pipeline observable and auditable:

    etl.seq_batch_id     - one id per pipeline run, stamped on every loaded row
                           (dwh_batch_id) and every log entry.
    etl.load_log         - one row per table loaded (rows, duration, status and,
                           on failure, the full error details from TRY...CATCH).
    etl.file_manifest    - the landing-zone manifest written by the extractor;
                           Bronze reconciles loaded row counts against it.
    etl.dq_rule          - catalogue of data-quality rules. Silver stamps each
                           trip with a bitmask (dq_flags) of the rules it breaks;
                           the severity decides whether Gold rejects or keeps it.
    etl.write_load_log   - helper procedure used by all load procedures.

    Run this script once after init_database.sql (it drops and recreates).
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- Explicit session settings: SSMS defaults them ON but sqlcmd does not, and
-- filtered indexes (and procedures that write to their tables) require them.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- -----------------------------------------------------------------------------
-- Batch id sequence
-- A SEQUENCE (rather than an IDENTITY on a batch table) lets the orchestrator
-- reserve the id before any table is touched and pass it down to every layer.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('etl.seq_batch_id', 'SO') IS NOT NULL
    DROP SEQUENCE etl.seq_batch_id;
GO

CREATE SEQUENCE etl.seq_batch_id AS INT START WITH 1 INCREMENT BY 1;
GO

-- -----------------------------------------------------------------------------
-- Load log
-- -----------------------------------------------------------------------------
IF OBJECT_ID('etl.load_log', 'U') IS NOT NULL
    DROP TABLE etl.load_log;
GO

CREATE TABLE etl.load_log (
    load_log_id      INT IDENTITY(1,1) NOT NULL,
    batch_id         INT               NOT NULL,
    layer            VARCHAR(10)       NOT NULL,
    object_name      NVARCHAR(128)     NOT NULL,
    status           VARCHAR(10)       NOT NULL,
    rows_affected    BIGINT            NULL,
    start_time       DATETIME2(3)      NOT NULL,
    end_time         DATETIME2(3)      NOT NULL,
    -- Computed so it can never disagree with start/end time.
    duration_seconds AS CAST(DATEDIFF(MILLISECOND, start_time, end_time) / 1000.0 AS DECIMAL(10,1)),
    error_number     INT               NULL,
    error_line       INT               NULL,
    error_procedure  NVARCHAR(128)     NULL,
    error_message    NVARCHAR(4000)    NULL,
    CONSTRAINT pk_load_log PRIMARY KEY CLUSTERED (load_log_id),
    CONSTRAINT ck_load_log_layer  CHECK (layer IN ('bronze', 'silver', 'gold', 'pipeline')),
    CONSTRAINT ck_load_log_status CHECK (status IN ('Succeeded', 'Failed'))
);
GO

-- -----------------------------------------------------------------------------
-- File manifest (landing zone contract)
-- -----------------------------------------------------------------------------
IF OBJECT_ID('etl.file_manifest', 'U') IS NOT NULL
    DROP TABLE etl.file_manifest;
GO

CREATE TABLE etl.file_manifest (
    file_name        VARCHAR(100) NOT NULL,
    source_system    VARCHAR(20)  NOT NULL,
    reporting_month  DATE         NOT NULL,
    source_file      VARCHAR(200) NOT NULL,
    row_count        BIGINT       NOT NULL,
    file_size_bytes  BIGINT       NOT NULL,
    extracted_at_utc DATETIME2(0) NOT NULL,
    CONSTRAINT pk_file_manifest PRIMARY KEY CLUSTERED (file_name)
);
GO

-- -----------------------------------------------------------------------------
-- Data-quality rule catalogue
-- rule_bit values are powers of two so several rules can be stored in one INT
-- (dq_flags) per trip and tested with a bitwise AND: dq_flags & rule_bit <> 0.
--   REJECT - the row stays in Silver (auditable) but is excluded from Gold.
--   WARN   - the row flows to Gold; the flag stays available for analysis.
-- -----------------------------------------------------------------------------
IF OBJECT_ID('etl.dq_rule', 'U') IS NOT NULL
    DROP TABLE etl.dq_rule;
GO

CREATE TABLE etl.dq_rule (
    rule_bit         INT          NOT NULL,
    rule_code        VARCHAR(30)  NOT NULL,
    rule_description VARCHAR(300) NOT NULL,
    severity         VARCHAR(6)   NOT NULL,
    CONSTRAINT pk_dq_rule PRIMARY KEY CLUSTERED (rule_bit),
    CONSTRAINT uq_dq_rule_code UNIQUE (rule_code),
    CONSTRAINT ck_dq_rule_severity CHECK (severity IN ('REJECT', 'WARN')),
    -- Guarantees each rule owns exactly one bit of the mask.
    CONSTRAINT ck_dq_rule_power_of_two CHECK (rule_bit > 0 AND (rule_bit & (rule_bit - 1)) = 0)
);
GO

INSERT INTO etl.dq_rule (rule_bit, rule_code, rule_description, severity)
VALUES
    (1,   'OUT_OF_PERIOD',       'Pickup is outside the reporting month of the file (late-arriving or mis-dated record).', 'REJECT'),
    (2,   'NEGATIVE_DURATION',   'Dropoff happens before pickup.', 'REJECT'),
    (4,   'EXCESSIVE_DURATION',  'Trip lasts more than 24 hours (e.g. FHV dropoff dated 2029).', 'REJECT'),
    (8,   'IMPLAUSIBLE_VALUE',   'Distance above 250 miles or an amount above $5,000 (meter/entry errors).', 'REJECT'),
    (16,  'ZERO_DURATION',       'Pickup and dropoff timestamps are identical.', 'WARN'),
    (32,  'NEGATIVE_AMOUNT',     'Negative total (taxi) or base fare (HVFHV): a reversal, refund or dispute adjustment rather than a new trip. Kept so revenue nets correctly, but counted as 0 trips in Gold.', 'WARN'),
    (64,  'MISSING_LOCATION',    'Pickup or dropoff zone not recorded (very common in FHV).', 'WARN'),
    (128, 'AMOUNT_NOT_RECONCILED', 'Taxi fare components do not add up to total_amount (known TPEP vendor behaviour).', 'WARN');
GO

-- -----------------------------------------------------------------------------
-- Helper: write one entry to the load log
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.write_load_log
    @batch_id        INT,
    @layer           VARCHAR(10),
    @object_name     NVARCHAR(128),
    @status          VARCHAR(10),
    @rows_affected   BIGINT         = NULL,
    @start_time      DATETIME2(3),
    @error_number    INT            = NULL,
    @error_line      INT            = NULL,
    @error_procedure NVARCHAR(128)  = NULL,
    @error_message   NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO etl.load_log (
        batch_id, layer, object_name, status, rows_affected, start_time, end_time,
        error_number, error_line, error_procedure, error_message
    )
    VALUES (
        @batch_id, @layer, @object_name, @status, @rows_affected, @start_time, SYSDATETIME(),
        @error_number, @error_line, @error_procedure, @error_message
    );

    PRINT CONCAT('>> ', @status, ': ', @object_name,
                 CASE WHEN @rows_affected IS NOT NULL THEN CONCAT(' | ', FORMAT(@rows_affected, 'N0'), ' rows') END,
                 ' | ', CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) / 1000.0 AS DECIMAL(10,1)), ' s');
END;
GO
