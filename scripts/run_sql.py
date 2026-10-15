#!/usr/bin/env python3
"""Render a SQL template with table paths from config and run it via the `bq` CLI.

Placeholders: {{ sources.<key> }}, {{ outputs.<key> }} (resolved to
<gcp.output_dataset>.<table>), and {{ gcp.<key> }}.

Examples:
  python scripts/run_sql.py sql/state/01_state_location_comparison.sql --print
  python scripts/run_sql.py sql/state/01_state_location_comparison.sql --dry-run
  python scripts/run_sql.py sql/state/01_state_location_comparison.sql
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = REPO_ROOT / "config" / "data_sources.yaml"
PLACEHOLDER = re.compile(r"\{\{\s*([\w.]+)\s*\}\}")


def build_context(cfg: dict) -> dict:
    ctx = {f"gcp.{k}": v for k, v in cfg["gcp"].items()}
    ctx.update({f"sources.{k}": v for k, v in cfg["sources"].items()})
    dataset = cfg["gcp"]["output_dataset"]
    ctx.update({f"outputs.{k}": f"{dataset}.{v}" for k, v in cfg["outputs"].items()})
    return ctx


def render(sql: str, ctx: dict) -> str:
    missing = sorted({m for m in PLACEHOLDER.findall(sql) if m not in ctx})
    if missing:
        sys.exit(f"Unknown placeholders: {', '.join(missing)}")
    return PLACEHOLDER.sub(lambda m: ctx[m.group(1)], sql)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("sql_file", type=Path)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--print", action="store_true", help="print rendered SQL and exit")
    group.add_argument("--dry-run", action="store_true", help="validate and estimate bytes processed")
    args = parser.parse_args()

    cfg = yaml.safe_load(args.config.read_text())
    sql = render(args.sql_file.read_text(), build_context(cfg))

    if args.print:
        print(sql)
        return

    cmd = ["bq", "query", "--use_legacy_sql=false", f"--project_id={cfg['gcp']['billing_project']}"]
    if args.dry_run:
        cmd.append("--dry_run")
    # SQL goes via stdin: as a positional arg, a leading "--" comment is parsed as a flag
    sys.exit(subprocess.run(cmd, input=sql, text=True).returncode)


if __name__ == "__main__":
    main()
