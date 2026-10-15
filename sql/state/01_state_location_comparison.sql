-- State-level comparison of FCC BDC location_ids vs Cotality address_ids.
-- FCC counts cover locations with fiber, cable or copper service only
-- (fixed wireless / satellite tables are not included).
-- Grain: one row per state (50 + DC), with geometry for CARTO.

CREATE OR REPLACE TABLE `{{ outputs.state_location_comparison }}` AS  -- clgx-gis-app-dev-06e3.work_eprashar.sm_state_location_comparison

WITH fcc AS (
  SELECT state_usps, location_id, technology FROM `{{ sources.fcc_fiber }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_common_reference_ext.fcc_fiber_fixed_broadband
  UNION ALL
  SELECT state_usps, location_id, technology FROM `{{ sources.fcc_cable }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_common_reference_ext.fcc_cable_fixed_broadband
  UNION ALL
  SELECT state_usps, location_id, technology FROM `{{ sources.fcc_copper }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_common_reference_ext.fcc_copper_fixed_broadband
),

fcc_state AS (
  SELECT
    state_usps AS state_abbrev,
    COUNT(DISTINCT location_id) AS fcc_location_ids,
    COUNT(DISTINCT IF(technology = 50, location_id, NULL)) AS fcc_fiber_location_ids,
    COUNT(DISTINCT IF(technology = 40, location_id, NULL)) AS fcc_cable_location_ids,
    COUNT(DISTINCT IF(technology = 10, location_id, NULL)) AS fcc_copper_location_ids
  FROM fcc
  WHERE location_id IS NOT NULL
  GROUP BY state_abbrev
),

cotality_state AS (
  SELECT
    -- normalise to 2-char zero-padded FIPS regardless of source type/format
    LPAD(CAST(FIPS_STATE_CODE AS STRING), 2, '0') AS state_fips,
    COUNT(DISTINCT ADDRESS_ID) AS cotality_address_ids,
    COUNT(DISTINCT CLIP) AS cotality_clips
  FROM `{{ sources.cotality_address }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_property_fulfillment_hist.address_connect_dsf
  WHERE ADDRESS_ID IS NOT NULL
  GROUP BY state_fips
)

SELECT
  s.state_fips,
  s.abbrev AS state_abbrev,
  s.state_name,
  IFNULL(f.fcc_location_ids, 0) AS fcc_location_ids,
  IFNULL(f.fcc_fiber_location_ids, 0) AS fcc_fiber_location_ids,
  IFNULL(f.fcc_cable_location_ids, 0) AS fcc_cable_location_ids,
  IFNULL(f.fcc_copper_location_ids, 0) AS fcc_copper_location_ids,
  IFNULL(c.cotality_address_ids, 0) AS cotality_address_ids,
  IFNULL(c.cotality_clips, 0) AS cotality_clips,
  IFNULL(c.cotality_address_ids, 0) - IFNULL(f.fcc_location_ids, 0) AS address_minus_fcc,
  ROUND(SAFE_DIVIDE(c.cotality_address_ids, f.fcc_location_ids), 4) AS address_to_fcc_ratio,
  s.geometry AS geom
FROM `{{ sources.states }}` AS s  -- clgx-gis-app-dev-06e3.teu_site_similarity.boundaries_states_2020
LEFT JOIN fcc_state AS f
  ON f.state_abbrev = s.abbrev
LEFT JOIN cotality_state AS c
  ON c.state_fips = s.state_fips
ORDER BY s.state_fips
