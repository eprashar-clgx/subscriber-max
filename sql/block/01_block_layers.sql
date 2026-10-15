-- Block-level layers (2020 census blocks). Builds two tables:
--   1. sm_block_provider_detail     one row per block x provider (brand_name), as a
--                                   point at the block's census interior point.
--                                   Feeds CARTO provider widgets.
--   2. sm_block_location_comparison one row per block (polygon): FCC location_ids vs
--                                   Cotality address_ids, plus provider counts and
--                                   top 3 providers (taken from table 1, so they match).
-- FCC data covers fiber, cable and copper only (no fixed wireless / satellite).
-- Provider = brand_name; fiber = technology 50.
-- Cotality addresses are assigned to blocks via point-in-polygon on LOCATION_WKT.
-- state_* columns come from the first 2 chars of block_geoid.

-- Two-digit state FIPS to process ('48' = Texas). Set to NULL for all states (expensive).
DECLARE target_state_fips STRING DEFAULT '48';

-- FCC rows for the target state, read once and reused below
CREATE TEMP TABLE fcc AS
SELECT
  block_geoid,
  location_id,
  technology,
  COALESCE(NULLIF(TRIM(brand_name), ''), CONCAT('provider_id ', CAST(provider_id AS STRING))) AS brand_name
FROM (
  SELECT block_geoid, location_id, technology, brand_name, provider_id FROM `{{ sources.fcc_fiber }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_common_reference_ext.fcc_fiber_fixed_broadband
  UNION ALL
  SELECT block_geoid, location_id, technology, brand_name, provider_id FROM `{{ sources.fcc_cable }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_common_reference_ext.fcc_cable_fixed_broadband
  UNION ALL
  SELECT block_geoid, location_id, technology, brand_name, provider_id FROM `{{ sources.fcc_copper }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_common_reference_ext.fcc_copper_fixed_broadband
)
WHERE location_id IS NOT NULL
  AND block_geoid IS NOT NULL
  AND (target_state_fips IS NULL OR LEFT(block_geoid, 2) = target_state_fips);

-- Block polygons + census interior point (always inside the block, unlike a centroid)
CREATE TEMP TABLE blocks AS
SELECT
  GEOID AS block_geoid,
  geom,
  ST_GEOGPOINT(SAFE_CAST(INTPTLON AS FLOAT64), SAFE_CAST(INTPTLAT AS FLOAT64)) AS interior_point
FROM `{{ sources.census_blocks }}`  -- clgx-gis-app-dev-06e3.boundary.census_block
WHERE target_state_fips IS NULL OR STATEFP = target_state_fips;

-- ---------------------------------------------------------------------------
-- 1. Block x provider detail
-- Note: summing `locations` across providers double-counts locations served by
-- several providers; use block_fcc_location_ids for unique locations.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{{ outputs.block_provider_detail }}`  -- clgx-gis-app-dev-06e3.work_eprashar.sm_block_provider_detail
CLUSTER BY geom
AS
WITH block_provider AS (
  SELECT
    block_geoid,
    brand_name,
    COUNT(DISTINCT location_id) AS locations,
    COUNT(DISTINCT IF(technology = 50, location_id, NULL)) AS fiber_locations
  FROM fcc
  GROUP BY block_geoid, brand_name
),

block_total AS (
  SELECT block_geoid, COUNT(DISTINCT location_id) AS block_fcc_location_ids
  FROM fcc
  GROUP BY block_geoid
)

SELECT
  bp.block_geoid,
  LEFT(bp.block_geoid, 2) AS state_fips,
  s.abbrev AS state_abbrev,
  s.state_name,
  bp.brand_name,
  -- 1 = serves most locations in the block; ties broken alphabetically
  ROW_NUMBER() OVER (PARTITION BY bp.block_geoid ORDER BY bp.locations DESC, bp.brand_name) AS provider_rank,
  bp.locations,
  bp.fiber_locations,
  bt.block_fcc_location_ids,
  ROUND(SAFE_DIVIDE(bp.locations, bt.block_fcc_location_ids), 4) AS location_share,
  -- NULL if the FCC block_geoid is not in the 2020 block boundaries
  b.interior_point AS geom
FROM block_provider AS bp
JOIN block_total AS bt
  USING (block_geoid)
LEFT JOIN blocks AS b
  USING (block_geoid)
LEFT JOIN `{{ sources.states }}` AS s  -- clgx-gis-app-dev-06e3.teu_site_similarity.boundaries_states_2020
  ON s.state_fips = LEFT(bp.block_geoid, 2);

-- ---------------------------------------------------------------------------
-- 2. Block location comparison + provider summary
-- Grain: one row per block present in either source (empty blocks are omitted).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{{ outputs.block_location_comparison }}`  -- clgx-gis-app-dev-06e3.work_eprashar.sm_block_location_comparison
CLUSTER BY geom
AS

WITH fcc_block AS (
  SELECT
    block_geoid,
    COUNT(DISTINCT location_id) AS fcc_location_ids,
    COUNT(DISTINCT IF(technology = 50, location_id, NULL)) AS fcc_fiber_location_ids,
    COUNT(DISTINCT IF(technology = 40, location_id, NULL)) AS fcc_cable_location_ids,
    COUNT(DISTINCT IF(technology = 10, location_id, NULL)) AS fcc_copper_location_ids
  FROM fcc
  GROUP BY block_geoid
),

block_providers AS (
  SELECT
    block_geoid,
    COUNT(*) AS total_providers,
    COUNTIF(fiber_locations > 0) AS fiber_providers,
    MAX(IF(provider_rank = 1, brand_name, NULL)) AS top_provider_1,
    MAX(IF(provider_rank = 1, locations, NULL)) AS top_provider_1_locations,
    MAX(IF(provider_rank = 2, brand_name, NULL)) AS top_provider_2,
    MAX(IF(provider_rank = 2, locations, NULL)) AS top_provider_2_locations,
    MAX(IF(provider_rank = 3, brand_name, NULL)) AS top_provider_3,
    MAX(IF(provider_rank = 3, locations, NULL)) AS top_provider_3_locations,
    -- e.g. "AT&T (40) | Spectrum (35) | Frontier (10)" for CARTO tooltips
    STRING_AGG(IF(provider_rank <= 3, FORMAT('%s (%d)', brand_name, locations), NULL), ' | ' ORDER BY provider_rank) AS top_providers_label
  FROM `{{ outputs.block_provider_detail }}`  -- clgx-gis-app-dev-06e3.work_eprashar.sm_block_provider_detail
  GROUP BY block_geoid
),

addresses AS (
  SELECT ADDRESS_ID, CLIP, LOCATION_WKT AS geog
  FROM `{{ sources.cotality_address }}`  -- clgx-idap-bigquery-prd-a990.edr_ent_property_fulfillment_hist.address_connect_dsf
  WHERE ADDRESS_ID IS NOT NULL
    AND LOCATION_WKT IS NOT NULL
    -- prefilter on attribute state to shrink the spatial join
    AND (target_state_fips IS NULL OR LPAD(CAST(FIPS_STATE_CODE AS STRING), 2, '0') = target_state_fips)
),

address_block AS (
  SELECT a.ADDRESS_ID, a.CLIP, b.block_geoid
  FROM addresses AS a
  JOIN blocks AS b
    ON ST_INTERSECTS(a.geog, b.geom)
  -- a point on a shared block edge can intersect two blocks; keep exactly one
  QUALIFY ROW_NUMBER() OVER (PARTITION BY a.ADDRESS_ID ORDER BY b.block_geoid) = 1
),

cotality_block AS (
  SELECT
    block_geoid,
    COUNT(DISTINCT ADDRESS_ID) AS cotality_address_ids,
    COUNT(DISTINCT CLIP) AS cotality_clips
  FROM address_block
  GROUP BY block_geoid
),

block_counts AS (
  SELECT
    block_geoid,
    IFNULL(f.fcc_location_ids, 0) AS fcc_location_ids,
    IFNULL(f.fcc_fiber_location_ids, 0) AS fcc_fiber_location_ids,
    IFNULL(f.fcc_cable_location_ids, 0) AS fcc_cable_location_ids,
    IFNULL(f.fcc_copper_location_ids, 0) AS fcc_copper_location_ids,
    IFNULL(c.cotality_address_ids, 0) AS cotality_address_ids,
    IFNULL(c.cotality_clips, 0) AS cotality_clips
  FROM fcc_block AS f
  FULL OUTER JOIN cotality_block AS c
    USING (block_geoid)
)

SELECT
  bc.block_geoid,
  LEFT(bc.block_geoid, 2) AS state_fips,
  s.abbrev AS state_abbrev,
  s.state_name,
  bc.fcc_location_ids,
  bc.fcc_fiber_location_ids,
  bc.fcc_cable_location_ids,
  bc.fcc_copper_location_ids,
  bc.cotality_address_ids,
  bc.cotality_clips,
  bc.cotality_address_ids - bc.fcc_location_ids AS address_minus_fcc,
  ROUND(SAFE_DIVIDE(bc.cotality_address_ids, bc.fcc_location_ids), 4) AS address_to_fcc_ratio,
  IFNULL(p.total_providers, 0) AS total_providers,
  IFNULL(p.fiber_providers, 0) AS fiber_providers,
  p.top_provider_1,
  p.top_provider_1_locations,
  p.top_provider_2,
  p.top_provider_2_locations,
  p.top_provider_3,
  p.top_provider_3_locations,
  p.top_providers_label,
  -- NULL if the FCC block_geoid is not in the 2020 block boundaries
  b.geom
FROM block_counts AS bc
LEFT JOIN block_providers AS p
  ON p.block_geoid = bc.block_geoid
LEFT JOIN blocks AS b
  ON b.block_geoid = bc.block_geoid
LEFT JOIN `{{ sources.states }}` AS s  -- clgx-gis-app-dev-06e3.teu_site_similarity.boundaries_states_2020
  ON s.state_fips = LEFT(bc.block_geoid, 2);
