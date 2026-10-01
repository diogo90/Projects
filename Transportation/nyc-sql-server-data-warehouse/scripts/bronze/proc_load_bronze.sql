/*
===============================================================================
Stored Procedures: Load Bronze Layer (Landing Zone -> Bronze)
===============================================================================
Script Purpose:
    Loads the CSV files produced by scripts/extract/extract_sources.py into the
    'bronze' tables using BULK INSERT (full load: truncate & insert).

    bronze.load_file   - loads ONE file into ONE table. Holds all the mechanics:
                         dynamic BULK INSERT, transaction, manifest
                         reconciliation, logging and error handling.
    bronze.load_bronze - loads the manifest, then every source file, in order.

Design notes:
    - Dynamic SQL: BULK INSERT only accepts a literal file path, so the path is
      assembled at run time. That keeps the landing folder a parameter instead
      of a path hard-coded in 7 places. The table name is validated with
      OBJECT_ID and wrapped in QUOTENAME, so nothing untrusted reaches EXEC.
    - Atomic table swap: TRUNCATE + BULK INSERT run inside ONE transaction.
      If the load fails the truncate is rolled back, so a failed run never
      leaves a Bronze table empty.
    - MAXERRORS = 0: by default BULK INSERT silently skips up to 10 bad rows.
      A warehouse must not lose rows quietly, so any parse error fails the file.
    - Manifest reconciliation: the rows loaded must equal the row count the
      extractor recorded in _manifest.csv, otherwise the file is rolled back.
    - TRY...CATCH: failures are written to etl.load_log with the full error
      context and then re-raised with THROW, so a caller (SQL Agent job,
      orchestrator, etl.run_pipeline) sees the batch fail. Printing the error
      and carrying on would hide failed loads.

Parameters (bronze.load_bronze):
    @landing_path  Folder containing the landing CSVs. Must be readable by the
                   SQL Server service account (e.g. NT Service\MSSQL$SQLEXPRESS).
    @batch_id      Optional. Supplied by etl.run_pipeline; generated if NULL.

Usage Example:
    EXEC bronze.load_bronze;
    EXEC bronze.load_bronze @landing_path = N'D:\data\landing\';
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- Explicit session settings: SSMS defaults them ON but sqlcmd does not, and
-- filtered indexes (and procedures that write to their tables) require them.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE bronze.load_file
    @batch_id                INT,
    @landing_path            NVARCHAR(260),
    @file_name               VARCHAR(100),
    @target_table            NVARCHAR(128),
    @reconcile_with_manifest BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @start_time     DATETIME2(3) = SYSDATETIME(),
            @rows_loaded    BIGINT,
            @rows_expected  BIGINT,
            @qualified_name NVARCHAR(300),
            @file_path      NVARCHAR(400),
            @sql            NVARCHAR(MAX),
            @message        NVARCHAR(2048);

    BEGIN TRY
        -- Validate inputs before building any dynamic SQL.
        IF OBJECT_ID(@target_table, 'U') IS NULL
        BEGIN
            SET @message = CONCAT('Target table does not exist: ', @target_table);
            THROW 50001, @message, 1;
        END;

        SET @qualified_name = QUOTENAME(PARSENAME(@target_table, 2)) + N'.' + QUOTENAME(PARSENAME(@target_table, 1));
        SET @file_path      = @landing_path + @file_name;

        IF @reconcile_with_manifest = 1
        BEGIN
            SELECT @rows_expected = row_count
            FROM etl.file_manifest
            WHERE file_name = @file_name;

            IF @rows_expected IS NULL
            BEGIN
                SET @message = CONCAT('File is not listed in the landing manifest: ', @file_name);
                THROW 50002, @message, 1;
            END;
        END;

        SET @sql = N'
            TRUNCATE TABLE ' + @qualified_name + N';
            BULK INSERT ' + @qualified_name + N'
            FROM ''' + REPLACE(@file_path, N'''', N'''''') + N'''
            WITH (
                FORMAT          = ''CSV'',     -- RFC 4180 parsing: handles quoted fields with commas
                FIRSTROW        = 2,           -- skip header row
                FIELDQUOTE      = ''"'',
                ROWTERMINATOR   = ''0x0a'',    -- LF, as written by the extractor
                CODEPAGE        = ''65001'',   -- UTF-8
                MAXERRORS       = 0,           -- never skip bad rows silently
                BATCHSIZE       = 1048576,     -- = max columnstore rowgroup size
                TABLOCK                        -- enables minimal logging
            );
            SET @rows_out = ROWCOUNT_BIG();';

        BEGIN TRANSACTION;

            EXEC sp_executesql @sql, N'@rows_out BIGINT OUTPUT', @rows_out = @rows_loaded OUTPUT;

            IF @reconcile_with_manifest = 1 AND @rows_loaded <> @rows_expected
            BEGIN
                SET @message = CONCAT('Row count mismatch for ', @file_name, ': manifest=', @rows_expected,
                                      ', loaded=', @rows_loaded, '. Load rolled back.');
                THROW 50003, @message, 1;
            END;

        COMMIT TRANSACTION;

        EXEC etl.write_load_log
            @batch_id = @batch_id, @layer = 'bronze', @object_name = @target_table,
            @status = 'Succeeded', @rows_affected = @rows_loaded, @start_time = @start_time;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @error_number    INT            = ERROR_NUMBER(),
                @error_line      INT            = ERROR_LINE(),
                @error_procedure NVARCHAR(128)  = ERROR_PROCEDURE(),
                @error_message   NVARCHAR(4000) = ERROR_MESSAGE();

        EXEC etl.write_load_log
            @batch_id = @batch_id, @layer = 'bronze', @object_name = @target_table,
            @status = 'Failed', @start_time = @start_time,
            @error_number = @error_number, @error_line = @error_line,
            @error_procedure = @error_procedure, @error_message = @error_message;

        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE bronze.load_bronze
    @landing_path NVARCHAR(260) = N'C:\sql\nyc_tlc_dwh\landing\',
    @batch_id     INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @layer_start DATETIME2(3) = SYSDATETIME();

    IF @batch_id IS NULL
        SET @batch_id = NEXT VALUE FOR etl.seq_batch_id;

    IF RIGHT(@landing_path, 1) <> N'\'
        SET @landing_path += N'\';

    BEGIN TRY
        PRINT '================================================';
        PRINT CONCAT('Loading Bronze Layer | batch_id = ', @batch_id);
        PRINT '================================================';

        -- 1. Manifest first: it is the contract every other file is checked against.
        PRINT '------------------------------------------------';
        PRINT 'Landing manifest';
        PRINT '------------------------------------------------';
        EXEC bronze.load_file @batch_id, @landing_path, '_manifest.csv', 'etl.file_manifest',
                              @reconcile_with_manifest = 0;

        -- 2. Reference data
        PRINT '------------------------------------------------';
        PRINT 'Reference sources (tlc, openmeteo)';
        PRINT '------------------------------------------------';
        EXEC bronze.load_file @batch_id, @landing_path, 'tlc_taxi_zone_lookup.csv',     'bronze.tlc_taxi_zone_lookup';
        EXEC bronze.load_file @batch_id, @landing_path, 'tlc_code_values.csv',          'bronze.tlc_code_values';
        EXEC bronze.load_file @batch_id, @landing_path, 'openmeteo_weather_hourly.csv', 'bronze.openmeteo_weather_hourly';

        -- 3. Trip records
        PRINT '------------------------------------------------';
        PRINT 'Trip record sources (yellow, green, fhv, fhvhv)';
        PRINT '------------------------------------------------';
        EXEC bronze.load_file @batch_id, @landing_path, 'yellow_tripdata.csv', 'bronze.yellow_tripdata';
        EXEC bronze.load_file @batch_id, @landing_path, 'green_tripdata.csv',  'bronze.green_tripdata';
        EXEC bronze.load_file @batch_id, @landing_path, 'fhv_tripdata.csv',    'bronze.fhv_tripdata';
        EXEC bronze.load_file @batch_id, @landing_path, 'fhvhv_tripdata.csv',  'bronze.fhvhv_tripdata';

        EXEC etl.write_load_log
            @batch_id = @batch_id, @layer = 'bronze', @object_name = 'bronze.load_bronze',
            @status = 'Succeeded', @start_time = @layer_start;

        PRINT '================================================';
        PRINT 'Loading Bronze Layer is Completed';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        DECLARE @error_number    INT            = ERROR_NUMBER(),
                @error_line      INT            = ERROR_LINE(),
                @error_procedure NVARCHAR(128)  = ERROR_PROCEDURE(),
                @error_message   NVARCHAR(4000) = ERROR_MESSAGE();

        PRINT '================================================';
        PRINT 'ERROR OCCURRED DURING LOADING BRONZE LAYER';
        PRINT CONCAT('Error Number : ', @error_number);
        PRINT CONCAT('Error Line   : ', @error_line);
        PRINT CONCAT('Error Message: ', @error_message);
        PRINT '================================================';

        EXEC etl.write_load_log
            @batch_id = @batch_id, @layer = 'bronze', @object_name = 'bronze.load_bronze',
            @status = 'Failed', @start_time = @layer_start,
            @error_number = @error_number, @error_line = @error_line,
            @error_procedure = @error_procedure, @error_message = @error_message;

        THROW;
    END CATCH;
END;
GO
