/* =============================================================================
   CURATED 01 - XBRL concept map (configuration-driven standardisation)
   -----------------------------------------------------------------------------
   Run as: VALUATION_PIPELINE

   THE PROBLEM
   Companies tag the same economic quantity with different US-GAAP concepts:
   banks report revenue as RevenuesNetOfInterestExpense, most corporates use
   RevenueFromContractWithCustomerExcludingAssessedTax (post ASC 606) or
   Revenues, and older filings use SalesRevenueNet. JPMorgan tags debt as
   LongTermDebtAndCapitalLeaseObligationsIncludingCurrentMaturities while
   Goldman uses UnsecuredLongTermDebt. 15 of the 50 companies never report
   a Liabilities total at all.

   THE APPROACH
   One standard METRIC maps to several CONCEPTS, ranked by PRIORITY. Per
   company and period, the highest-priority concept that exists wins. Adding a
   new tag variant is a one-row INSERT, not a code change. Coverage figures in
   the comments come from profiling the 50-company extract.
============================================================================= */
USE ROLE VALUATION_PIPELINE;
USE SCHEMA VALUATION_DB.CURATED;

CREATE OR REPLACE TRANSIENT TABLE REF_XBRL_CONCEPT_MAP (
    metric          VARCHAR      NOT NULL,   -- standard column name downstream
    taxonomy        VARCHAR      NOT NULL,   -- us-gaap | dei
    concept         VARCHAR      NOT NULL,   -- XBRL element name
    unit            VARCHAR      NOT NULL,   -- USD | USD/shares | shares
    priority        NUMBER(3,0)  NOT NULL,   -- 1 = preferred
    value_kind      VARCHAR      NOT NULL,   -- DURATION (flow) | INSTANT (stock)
    statement       VARCHAR      NOT NULL,   -- IS | BS | CF
    is_per_share    BOOLEAN      NOT NULL,   -- per-share values need split adjustment
    CONSTRAINT pk_ref_xbrl_concept_map PRIMARY KEY (metric, concept)
)
COMMENT = 'Priority-ranked mapping of XBRL concepts to standard fundamental metrics';

INSERT INTO REF_XBRL_CONCEPT_MAP VALUES
    -- Income statement (flows: reported per quarter and year-to-date)
    ('revenue',             'us-gaap', 'Revenues',                                                        'USD',        1, 'DURATION', 'IS', FALSE),
    ('revenue',             'us-gaap', 'RevenueFromContractWithCustomerExcludingAssessedTax',             'USD',        2, 'DURATION', 'IS', FALSE),
    ('revenue',             'us-gaap', 'RevenuesNetOfInterestExpense',                                    'USD',        3, 'DURATION', 'IS', FALSE),
    ('revenue',             'us-gaap', 'SalesRevenueNet',                                                 'USD',        4, 'DURATION', 'IS', FALSE),
    ('net_income',          'us-gaap', 'NetIncomeLoss',                                                   'USD',        1, 'DURATION', 'IS', FALSE),
    ('net_income',          'us-gaap', 'NetIncomeLossAvailableToCommonStockholdersBasic',                 'USD',        2, 'DURATION', 'IS', FALSE),
    ('net_income',          'us-gaap', 'ProfitLoss',                                                      'USD',        3, 'DURATION', 'IS', FALSE),
    ('eps_diluted',         'us-gaap', 'EarningsPerShareDiluted',                                         'USD/shares', 1, 'DURATION', 'IS', TRUE),
    ('eps_diluted',         'us-gaap', 'EarningsPerShareBasicAndDiluted',                                 'USD/shares', 2, 'DURATION', 'IS', TRUE),
    ('eps_diluted',         'us-gaap', 'EarningsPerShareBasic',                                           'USD/shares', 3, 'DURATION', 'IS', TRUE),
    -- Cash flow statement (10-Q reports YEAR-TO-DATE only -> discrete quarters are derived)
    ('operating_cash_flow', 'us-gaap', 'NetCashProvidedByUsedInOperatingActivities',                      'USD',        1, 'DURATION', 'CF', FALSE),
    -- Balance sheet (stocks: point-in-time)
    ('total_assets',        'us-gaap', 'Assets',                                                          'USD',        1, 'INSTANT',  'BS', FALSE),
    ('total_liabilities',   'us-gaap', 'Liabilities',                                                     'USD',        1, 'INSTANT',  'BS', FALSE),
    ('liabilities_and_equity','us-gaap','LiabilitiesAndStockholdersEquity',                               'USD',        1, 'INSTANT',  'BS', FALSE),
    ('total_equity',        'us-gaap', 'StockholdersEquity',                                              'USD',        1, 'INSTANT',  'BS', FALSE),
    ('total_equity',        'us-gaap', 'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest', 'USD', 2, 'INSTANT',  'BS', FALSE),
    ('total_equity_incl_nci','us-gaap','StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest', 'USD', 1, 'INSTANT',  'BS', FALSE),
    ('total_equity_incl_nci','us-gaap','StockholdersEquity',                                              'USD',        2, 'INSTANT',  'BS', FALSE),
    ('long_term_debt',      'us-gaap', 'LongTermDebt',                                                    'USD',        1, 'INSTANT',  'BS', FALSE),
    ('long_term_debt',      'us-gaap', 'LongTermDebtAndCapitalLeaseObligationsIncludingCurrentMaturities','USD',        2, 'INSTANT',  'BS', FALSE),
    ('long_term_debt',      'us-gaap', 'LongTermDebtAndCapitalLeaseObligations',                          'USD',        3, 'INSTANT',  'BS', FALSE),
    ('long_term_debt',      'us-gaap', 'LongTermDebtNoncurrent',                                          'USD',        4, 'INSTANT',  'BS', FALSE),
    ('long_term_debt',      'us-gaap', 'UnsecuredLongTermDebt',                                           'USD',        5, 'INSTANT',  'BS', FALSE),
    ('short_term_borrowings','us-gaap','ShortTermBorrowings',                                             'USD',        1, 'INSTANT',  'BS', FALSE),
    ('short_term_borrowings','us-gaap','CommercialPaper',                                                 'USD',        2, 'INSTANT',  'BS', FALSE),
    ('cash_and_equivalents','us-gaap', 'CashAndCashEquivalentsAtCarryingValue',                           'USD',        1, 'INSTANT',  'BS', FALSE),
    ('cash_and_equivalents','us-gaap', 'CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents',   'USD',        2, 'INSTANT',  'BS', FALSE);
