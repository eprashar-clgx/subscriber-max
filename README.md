# subscriber-max

Subscriber maximization: Cotality + FCC BDC data layers in BigQuery, visualised in CARTO for client feedback.

## Layout

- `config/data_sources.yaml` holds all source and output table paths. SQL references them as `{{ sources.<key> }}` and `{{ outputs.<key> }}`.
- `sql/` contains the SQL templates, one folder per geography.
- `scripts/run_sql.py` fills in a template and runs it with the `bq` CLI.

## Running

Requires `bq` (gcloud SDK) authenticated with read access to `clgx-idap-bigquery-prd-a990` and write access to `work_eprashar`.

```bash
pip install -r requirements.txt
python scripts/run_sql.py sql/state/01_state_location_comparison.sql --print    # show rendered SQL (paste into console)
python scripts/run_sql.py sql/state/01_state_location_comparison.sql --dry-run  # validate + bytes estimate
python scripts/run_sql.py sql/state/01_state_location_comparison.sql            # build table
```

## Layers

| Table (`work_eprashar`) | Grain | Description |
|---|---|---|
| `sm_state_location_comparison` | State (50 + DC) | Counts FCC location_ids (fiber/cable/copper, plus a per-technology breakdown) against Cotality address_ids and CLIPs (on `FIPS_STATE_CODE`). Also includes the difference, the ratio and the state geometry. |
| `sm_block_location_comparison` | 2020 census block (polygon) | Same metrics as the state table. Adds `total_providers`, `fiber_providers`, `top_provider_1..3` (each with `_locations`) and `top_providers_label` for tooltips. State name/abbrev come from `LEFT(block_geoid, 2)`. Cotality addresses are placed in blocks by point-in-polygon on `LOCATION_WKT`. Only blocks present in at least one source are kept. |
| `sm_block_provider_detail` | Block x provider (point at the block's census interior point) | `brand_name`, `provider_rank`, `locations`, `fiber_locations`, `block_fcc_location_ids`, `location_share`. Use it for CARTO Category widgets: `brand_name` with SUM(`locations`) or SUM(`fiber_locations`). Sums across providers double-count locations served by more than one provider. |
| `sm_address_firmographics` | Cotality address (point) | Address attributes (`clip`, `std_match_address`, quality score, res/bus, land use, child count) left-joined to firmographics on `address_id`. Includes every address; `has_business` flags matches. `business_count` = number of firmographic records at the address. The business/corporate/NAICS/SIC columns describe the largest one (corporate employees, then revenue). Built by `sql/address/01_address_firmographics.sql` (same `target_state_fips` scoping). |

Both block tables are built by `sql/block/01_block_layers.sql`, scoped by `DECLARE target_state_fips` at the top (default `'48'` = Texas; NULL = all states).
Provider = FCC `brand_name` (trimmed; falls back to `provider_id <n>` when blank). Fiber = technology 50. Ties in provider rank are broken alphabetically.
