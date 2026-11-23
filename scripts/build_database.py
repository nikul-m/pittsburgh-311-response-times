"""Rebuild the SQLite database from the raw WPRDC 311 CSV and create every analysis view.

Usage, from the repo root:
    python scripts/build_database.py data/<downloaded file>.csv

What it does:
  1. Loads the CSV into a table called `requests` (every column stored as TEXT).
  2. Runs sql/02_clean.sql and sql/03_results.sql, which create the views
     in_scope, analysis, model_data and model_data_14d.
Overwrites data/pgh311.db if it exists. Takes under a minute.
"""
import csv
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DB = ROOT / "data" / "pgh311.db"
SQL_FILES = [ROOT / "sql" / "02_clean.sql", ROOT / "sql" / "03_results.sql"]


def build(csv_path, db_path=DEFAULT_DB):
    db_path = Path(db_path)
    if db_path.exists():
        db_path.unlink()
    con = sqlite3.connect(db_path)

    csv.field_size_limit(2**31 - 1)  # some free-text fields are long
    # utf-8-sig silently drops a byte-order mark, which some download options add
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        rows = csv.reader(f)
        header = next(rows)
        columns = ", ".join(f'"{name}" TEXT' for name in header)
        con.execute(f"CREATE TABLE requests ({columns})")
        placeholders = ", ".join("?" * len(header))
        con.executemany(f"INSERT INTO requests VALUES ({placeholders})", rows)
    con.commit()

    for sql_file in SQL_FILES:
        con.executescript(sql_file.read_text(encoding="utf-8"))
    con.commit()

    n_rows = con.execute("SELECT COUNT(*) FROM requests").fetchone()[0]
    n_model = con.execute("SELECT COUNT(*) FROM model_data").fetchone()[0]
    print(f"{db_path}: {n_rows:,} requests loaded; model_data has {n_model:,} rows")
    con.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    build(*sys.argv[1:3])
