/*
===============================================================================
Stored Procedure: Run the Full Pipeline (Landing -> Bronze -> Silver -> Gold)
===============================================================================
Script Purpose:
    Single entry point for a batch run. Reserves one batch_id and passes it to
    every layer, so every row loaded and every etl.load_log entry of the run
    share the same id. A failure in any layer stops the run (THROW), leaving
    the later layers untouched and still serving the previous successful load.

    Deploy this script after the three layer procedures.

Parameters:
    @landing_path  Folder with the landing CSVs (see bronze.load_bronze).

Usage Example:
    EXEC etl.run_pipeline;

    -- Inspect the run:
    SELECT * FROM etl.load_log WHERE batch_id = (SELECT MAX(batch_id) FROM etl.load_log) ORDER BY load_log_id;
===============================================================================
*/

USE nyc_tlc_dwh;
GO

-- Explicit session settings: SSMS defaults them ON but sqlcmd does not, and
-- filtered indexes (and procedures that write to their tables) require them.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE etl.run_pipeline
    @landing_path NVARCHAR(260) = N'C:\sql\nyc_tlc_dwh\landing\'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch_id       INT          = NEXT VALUE FOR etl.seq_batch_id,
            @pipeline_start DATETIME2(3) = SYSDATETIME();

    BEGIN TRY
        PRINT CONCAT('##### Pipeline started | batch_id = ', @batch_id, ' #####');

        EXEC bronze.load_bronze @landing_path = @landing_path, @batch_id = @batch_id;
        EXEC silver.load_silver @batch_id = @batch_id;
        EXEC gold.load_gold     @batch_id = @batch_id;

        EXEC etl.write_load_log @batch_id, 'pipeline', N'etl.run_pipeline', 'Succeeded', NULL, @pipeline_start;
        PRINT CONCAT('##### Pipeline completed | batch_id = ', @batch_id, ' #####');
    END TRY
    BEGIN CATCH
        DECLARE @error_number    INT            = ERROR_NUMBER(),
                @error_line      INT            = ERROR_LINE(),
                @error_procedure NVARCHAR(128)  = ERROR_PROCEDURE(),
                @error_message   NVARCHAR(4000) = ERROR_MESSAGE();

        -- The layer that failed has already logged its own details;
        -- this entry marks the run as a whole as failed.
        EXEC etl.write_load_log
            @batch_id = @batch_id, @layer = 'pipeline', @object_name = N'etl.run_pipeline',
            @status = 'Failed', @start_time = @pipeline_start,
            @error_number = @error_number, @error_line = @error_line,
            @error_procedure = @error_procedure, @error_message = @error_message;

        THROW;
    END CATCH;
END;
GO
