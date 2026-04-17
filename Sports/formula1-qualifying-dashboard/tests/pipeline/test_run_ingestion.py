"""
test_run_ingestion.py

Tests the orchestration logic of the pipeline.
"""

from unittest.mock import patch, MagicMock
from f1_qualifying_dashboard.pipeline.run_ingestion import run_ingestion


@patch("f1_qualifying_dashboard.pipeline.run_ingestion.save_qualifying_to_duckdb")
@patch("f1_qualifying_dashboard.pipeline.run_ingestion.validate_qualifying_df")
@patch("f1_qualifying_dashboard.pipeline.run_ingestion.load_qualifying_data")
def test_run_ingestion_calls_all_steps(mock_load, mock_validate, mock_save):
    mock_load.return_value = MagicMock()
    mock_validate.return_value = MagicMock()

    run_ingestion(2023, 20)

    mock_load.assert_called_once()
    mock_validate.assert_called_once()
    mock_save.assert_called_once()