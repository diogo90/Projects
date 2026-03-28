-- STAGING MODEL
-- Pulls raw data from the DuckDB source table and exposes it cleanly.

with source as (

    select 
        date,
        symbol,
        twitterPosts,
        twitterComments,
        twitterLikes,
        twitterImpressions,
        twitterSentiment
    
    from {{ source('twitter_sentiment_source', 'twitter_sentiment') }}

)

select * from source