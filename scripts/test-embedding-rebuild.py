#!/usr/bin/env python3
"""Run the distribution-owned embedding qualification harness."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).resolve().parent.parent / 'clickhouse-migrate-embed/test/scripts/test-embedding-rebuild.py'), run_name='__main__')
