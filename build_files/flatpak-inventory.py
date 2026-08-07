#!/usr/bin/python3
"""Dump the host's installed Flatpak apps into a SQLite database.

osquery has no native flatpak_packages table (unlike deb_packages /
rpm_packages), so Fleet can't see Flatpak apps out of the box. This script
is the missing piece: osquery's Automatic Table Construction (ATC) feature
can expose an arbitrary SQLite table as a normal queryable table, so this
just needs to keep one up to date. Point Fleet's agent_options at the
database/table this script (re)builds and `SELECT * FROM flatpak_packages`
works like any built-in osquery package table. See CLAUDE.md ("Flatpak
Inventory for Fleet/osquery") for the exact agent_options snippet.

Run periodically by flatpak-inventory.timer (see the matching .service in
this directory). Rebuilds the table from scratch on every run — via
DROP+CREATE — rather than diffing, so apps removed since the last run
disappear instead of lingering as stale rows.

Only the system-wide Flatpak installation (/var/lib/flatpak) is covered,
since this runs as root via a system timer; per-user installations under
~/.local/share/flatpak are not enumerated.
"""

import os
import shutil
import sqlite3
import subprocess
import sys

DB_PATH = "/var/lib/flatpak-inventory/flatpak.db"
TABLE = "flatpak_packages"
COLUMNS = ["application", "version", "branch", "origin", "ref", "installation"]


def flatpak_rows() -> list[list[str]]:
    flatpak = shutil.which("flatpak")
    if not flatpak:
        return []

    # --columns requests a stable, script-friendly (tab-separated, no
    # header) output format; the default human-oriented table layout is
    # explicitly documented as subject to change between flatpak versions.
    proc = subprocess.run(
        [flatpak, "list", "--app", "--columns=" + ",".join(COLUMNS)],
        check=True,
        capture_output=True,
        text=True,
    )

    rows = []
    for line in proc.stdout.splitlines():
        fields = line.split("\t")
        # Defensively skip anything that doesn't match the requested
        # column count instead of raising — a stray header/warning line
        # should never take the whole inventory run down.
        if len(fields) == len(COLUMNS):
            rows.append(fields)
    return rows


def main() -> int:
    rows = flatpak_rows()

    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute(f"DROP TABLE IF EXISTS {TABLE}")
        conn.execute(
            "CREATE TABLE {} ({})".format(
                TABLE, ", ".join(f"{column} TEXT" for column in COLUMNS)
            )
        )
        conn.executemany(
            "INSERT INTO {} VALUES ({})".format(
                TABLE, ", ".join("?" for _ in COLUMNS)
            ),
            rows,
        )
        conn.commit()
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
