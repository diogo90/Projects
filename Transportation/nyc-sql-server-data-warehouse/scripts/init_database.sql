/*
===============================================================================
Create Database and Schemas
===============================================================================
Script Purpose:
    Creates the 'nyc_tlc_dwh' database (dropping it first if it exists) and the
    four schemas used by the warehouse:
        etl     - pipeline control: batch log, file manifest, data-quality rules
        bronze  - raw data, loaded as-is from the landing zone
        silver  - cleansed, standardised, conformed data
        gold    - business-ready star schema (dimensions + facts)

Design notes:
    - RECOVERY SIMPLE: the warehouse is fully rebuildable from the source files
      (full-load design), so point-in-time restore is not needed. SIMPLE also
      allows minimally-logged bulk loads (BULK INSERT / INSERT ... WITH (TABLOCK)),
      which keeps the transaction log small when loading ~26M rows.
    - Files are pre-sized so the ~25M row load does not trigger dozens of small
      autogrowth events (each one pauses the load while the file is zeroed/grown).

WARNING:
    Running this script drops the entire 'nyc_tlc_dwh' database if it exists.
    All data in the database will be permanently deleted.
===============================================================================
*/

USE master;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'nyc_tlc_dwh')
BEGIN
    ALTER DATABASE nyc_tlc_dwh SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE nyc_tlc_dwh;
END;
GO

CREATE DATABASE nyc_tlc_dwh;
GO

ALTER DATABASE nyc_tlc_dwh SET RECOVERY SIMPLE;
GO

-- Pre-size data and log files (logical names default to the database name).
ALTER DATABASE nyc_tlc_dwh MODIFY FILE (NAME = N'nyc_tlc_dwh',     SIZE = 2GB, FILEGROWTH = 512MB);
ALTER DATABASE nyc_tlc_dwh MODIFY FILE (NAME = N'nyc_tlc_dwh_log', SIZE = 1GB, FILEGROWTH = 512MB);
GO

USE nyc_tlc_dwh;
GO

CREATE SCHEMA etl;
GO
CREATE SCHEMA bronze;
GO
CREATE SCHEMA silver;
GO
CREATE SCHEMA gold;
GO
