-- INTERMEDIATE MODEL
-- Adds engagement_ratio and filters out low-engagement rows.

with twitter_sentiment as (

    select 
        date,
        symbol,
        twitterPosts,
        twitterComments,
        twitterLikes,
        twitterImpressions,
        twitterSentiment,
        twitterComments / twitterLikes as engagement_ratio

    from {{ ref('stg_twitter_sentiment') }} 

    where twitterLikes > 20 
      and twitterComments > 10 

)

select * from twitter_sentiment