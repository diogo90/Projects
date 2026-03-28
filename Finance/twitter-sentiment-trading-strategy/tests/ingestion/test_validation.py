"""
tests/ingestion/test_validation.py

This module contains tests for the data validation logic used in the
Twitter sentiment ingestion pipeline.

Each test constructs a small in-memory DataFrame and passes it to
`validate_twitter_sentiment_df`, asserting that:

- valid data passes validation
- invalid data raises clear errors
- edge cases (like null sentiment) behave as expected
"""

import pandas as pd
import pytest

from ingestion.local_loader import validate_twitter_sentiment_df


def test_valid_data_passes():
    """
    GIVEN a DataFrame with a single, fully valid row
    WHEN we call validate_twitter_sentiment_df
    THEN validation should succeed and return exactly one validated row.
    """
    df = pd.DataFrame(
        [
            {
                "date": "2021-11-18",
                "symbol": "AAPL",
                "twitterPosts": 100,
                "twitterComments": 200,
                "twitterLikes": 300,
                "twitterImpressions": 4000,
                "twitterSentiment": 0.5,
            }
        ]
    )

    rows = validate_twitter_sentiment_df(df)
    assert len(rows) == 1


def test_invalid_sentiment_fails():
    """
    GIVEN a DataFrame where twitterSentiment is outside the allowed range [-1, 1]
    WHEN we call validate_twitter_sentiment_df
    THEN we expect a ValueError to be raised due to the Pydantic validator.
    """
    df = pd.DataFrame(
        [
            {
                "date": "2021-11-18",
                "symbol": "AAPL",
                "twitterPosts": 100,
                "twitterComments": 200,
                "twitterLikes": 300,
                "twitterImpressions": 4000,
                "twitterSentiment": 5.0,  # invalid
            }
        ]
    )

    with pytest.raises(ValueError):
        validate_twitter_sentiment_df(df)


def test_null_sentiment_allowed():
    """
    GIVEN a DataFrame where twitterSentiment is null
    WHEN we call validate_twitter_sentiment_df
    THEN validation should succeed and the resulting model should have
    twitterSentiment set to None.
    """
    df = pd.DataFrame(
        [
            {
                "date": "2021-11-18",
                "symbol": "AAPL",
                "twitterPosts": 100,
                "twitterComments": 200,
                "twitterLikes": 300,
                "twitterImpressions": 4000,
                "twitterSentiment": None,
            }
        ]
    )

    rows = validate_twitter_sentiment_df(df)
    assert rows[0].twitterSentiment is None


def test_missing_column_fails():
    """
    GIVEN a DataFrame missing a required column (twitterComments)
    WHEN we call validate_twitter_sentiment_df
    THEN we expect a ValueError because the Pydantic model requires that field.
    """
    df = pd.DataFrame(
        [
            {
                "date": "2021-11-18",
                "symbol": "AAPL",
                "twitterPosts": 100,
                # missing twitterComments
                "twitterLikes": 300,
                "twitterImpressions": 4000,
                "twitterSentiment": 0.1,
            }
        ]
    )

    with pytest.raises(ValueError):
        validate_twitter_sentiment_df(df)


def test_wrong_type_fails():
    """
    GIVEN a DataFrame where twitterPosts is a string instead of an int
    WHEN we call validate_twitter_sentiment_df
    THEN we expect a ValueError because the type does not match the model.
    """
    df = pd.DataFrame(
        [
            {
                "date": "2021-11-18",
                "symbol": "AAPL",
                "twitterPosts": "not a number",  # wrong type
                "twitterComments": 200,
                "twitterLikes": 300,
                "twitterImpressions": 4000,
                "twitterSentiment": 0.1,
            }
        ]
    )

    with pytest.raises(ValueError):
        validate_twitter_sentiment_df(df)