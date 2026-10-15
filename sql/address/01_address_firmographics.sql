-- Address point layer: Cotality addresses left-joined to firmographics on address_id.
-- Grain: one point per address (all addresses, residential included; firmographic
-- columns are NULL where there is no match).
-- When an address has several firmographic records, business_count holds the number
-- of records and the business_* / corporate_* / code columns describe the largest one
-- (most corporate employees, then revenue, then legal name).
-- Note: corporate_* figures are company-wide, not site-level.

-- Two-digit state FIPS to process ('48' = Texas). Set to NULL for all states (expensive).
DECLARE target_state_fips STRING DEFAULT '48';

CREATE OR REPLACE TABLE `{{ outputs.address_firmographics }}`  -- clgx-gis-app-dev-06e3.work_eprashar.sm_address_firmographics
CLUSTER BY geom
AS

WITH addresses AS (
  SELECT
    ADDRESS_ID AS address_id,
    CLIP AS clip,
    STD_MATCH_ADDRESS AS std_match_address,
    LPAD(CAST(FIPS_STATE_CODE AS STRING), 2, '0') AS state_fips,
    ADDRESS_QUALITY_SCORE AS address_quality_score,
    PREDOMINANT_RES_BUS AS predominant_res_bus,
    LAND_USE_CODE AS land_use_code,
    BASE_ADDRESS_CHILD_COUNT AS base_address_child_count,
    LOCATION_WKT AS geom
  FROM `{{ sources.cotality_address }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_property_fulfillment_hist.address_connect_dsf
  WHERE ADDRESS_ID IS NOT NULL
    AND LOCATION_WKT IS NOT NULL
    AND (target_state_fips IS NULL OR LPAD(CAST(FIPS_STATE_CODE AS STRING), 2, '0') = target_state_fips)
  -- safeguard: keep one row per address_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ADDRESS_ID ORDER BY CLIP) = 1
),

firmographics AS (
  SELECT
    f.address_id,
    f.business_brand_name,
    f.business_legal_name,
    f.corporate_number_of_employees,
    f.corporate_revenue_sales_amount,
    f.naics_6_digit_primary_code,
    f.sic_4_digit_primary_code,
    COUNT(*) OVER (PARTITION BY f.address_id) AS business_count
  FROM `{{ sources.cotality_firmographics }}` AS f  -- clgx-idap-bigquery-prd-a990.edr_ent_property_firmographics.vw_edr_firmographics_enterprise
  WHERE f.address_id IN (SELECT address_id FROM addresses)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY f.address_id
    ORDER BY
      f.corporate_number_of_employees DESC NULLS LAST,
      f.corporate_revenue_sales_amount DESC NULLS LAST,
      f.business_legal_name,
      f.business_brand_name
  ) = 1
)

SELECT
  a.address_id,
  a.clip,
  a.std_match_address,
  a.state_fips,
  a.address_quality_score,
  a.predominant_res_bus,
  a.land_use_code,
  a.base_address_child_count,
  f.address_id IS NOT NULL AS has_business,
  IFNULL(f.business_count, 0) AS business_count,
  f.business_brand_name,
  f.business_legal_name,
  f.corporate_number_of_employees,
  f.corporate_revenue_sales_amount,
  f.naics_6_digit_primary_code,
  f.sic_4_digit_primary_code,
  a.geom
FROM addresses AS a
LEFT JOIN firmographics AS f
  ON f.address_id = a.address_id;
