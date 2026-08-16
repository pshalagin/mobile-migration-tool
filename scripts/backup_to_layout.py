#!/usr/bin/env python3
"""The reverse of build_layout_backup.py: read a real .lawnchairbackup
(e.g. one you just exported after manually rearranging icons on the
phone) and write out an official layout TSV that matches it exactly —
positions included. Use this to pull manual on-device edits back into
the tracked source of truth, instead of hand-editing the TSV to match.

    python3 scripts/backup_to_layout.py \\
        --backup state/migration/<serial>_reference.lawnchairbackup \\
        --out state/migration/<serial>_layout.tsv

Reads the same `favorites` table build_layout_backup.py writes:
  - container=-101 (hotseat) -> page "dock". Per the hotseat quirk
    (documented in build_layout_backup.py), `screen` IS the slot index
    for dock rows, not cellX -- both are read but screen wins if they
    disagree.
  - container=-100 (workspace) -> page = screen + 1.
  - itemType=2 rows are folders: title becomes `blob`, children are
    looked up via container=<folder _id>, ordered by rank/position.
  - itemType=0 rows at the top level are standalone icons (blob empty).
  - cellX/cellY of the top-level icon or folder are written out as
    col/row, so the TSV pins the exact on-device position, not just
    membership.
  - pkg is parsed out of the intent string (`component=pkg/Activity` or
    `package=pkg`).

Widgets and anything else that isn't itemType 0/2 are skipped with a
warning -- this tool only round-trips icons/folders, same as the
builder only ever writes those.
"""
import argparse
import csv
import re
import shutil
import sqlite3
import sys
import tempfile
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = REPO_ROOT / "state"
APP_INFO_FILE = STATE_DIR / "app_info.tsv"

INTENT_RE = re.compile(r"(?:component|package)=([^;]+);")


def load_app_names():
    if not APP_INFO_FILE.exists():
        return {}
    with open(APP_INFO_FILE, newline="", encoding="utf-8-sig") as f:
        return {r["package"]: r.get("name", "") for r in csv.DictReader(f, delimiter="\t")}


def pkg_from_intent(intent):
    if not intent:
        return None
    m = INTENT_RE.search(intent)
    if not m:
        return None
    val = m.group(1)
    return val.split("/")[0] if "/" in val else val


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backup", required=True, type=Path, help="A real .lawnchairbackup to read.")
    ap.add_argument("--out", required=True, type=Path, help="Layout TSV to write.")
    args = ap.parse_args()

    if not args.backup.exists():
        sys.exit(f"Backup not found: {args.backup}")

    names = load_app_names()

    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(args.backup) as zf:
            zf.extractall(tmp)
        db_path = Path(tmp) / "launcher.db"
        if not db_path.exists():
            sys.exit(f"No launcher.db inside {args.backup} — is this a real Lawnchair backup?")
        con = sqlite3.connect(db_path)
        cur = con.cursor()
        cur.execute("SELECT _id,title,intent,container,screen,cellX,cellY,itemType,rank "
                    "FROM favorites")
        all_rows = cur.fetchall()
        con.close()

    by_id = {r[0]: r for r in all_rows}
    children_by_folder = {}
    for r in all_rows:
        _id, title, intent, container, screen, cellX, cellY, itemType, rank = r
        if container not in (-101, -100):
            children_by_folder.setdefault(container, []).append(r)

    out_rows = []
    skipped = []

    top_level = [r for r in all_rows if r[3] in (-101, -100)]

    def page_for(container, screen):
        return "dock" if container == -101 else str(screen + 1)

    for r in top_level:
        _id, title, intent, container, screen, cellX, cellY, itemType, rank = r
        page = page_for(container, screen)
        # Hotseat quirk: for dock rows, `screen` is the real slot index —
        # use it as the effective column instead of cellX if they differ.
        eff_col = screen if container == -101 else cellX
        eff_row = 0 if container == -101 else cellY

        if itemType == 0:
            pkg = pkg_from_intent(intent)
            if not pkg:
                skipped.append((title, "app row with unparseable intent"))
                continue
            out_rows.append({
                "page": page, "blob": "", "order": "1",
                "col": str(eff_col), "row": str(eff_row),
                "pkg": pkg, "name": names.get(pkg, ""), "note": "",
            })
        elif itemType == 2:
            kids = children_by_folder.get(_id, [])
            kids.sort(key=lambda k: (k[4], k[6], k[5]))  # screen (internal page), cellY, cellX -- rank ties broken by grid position
            if not kids:
                skipped.append((title, "empty folder, no children"))
                continue
            for i, k in enumerate(kids, 1):
                k_pkg = pkg_from_intent(k[2])
                if not k_pkg:
                    skipped.append((f"{title}/{k[1]}", "folder item with unparseable intent"))
                    continue
                out_rows.append({
                    "page": page, "blob": title or f"Folder{_id}", "order": str(i),
                    "col": str(eff_col) if i == 1 else "",
                    "row": str(eff_row) if i == 1 else "",
                    "pkg": k_pkg, "name": names.get(k_pkg, ""), "note": "",
                })
        else:
            skipped.append((title, f"itemType={itemType} (widget/other) — not round-tripped"))

    # Sort for a readable file: dock first, then pages in order, top-to-
    # bottom/left-to-right within each (matches the on-device reading
    # order, since eff_row/eff_col came straight from the device).
    def sort_key(r):
        page_rank = -1 if r["page"] == "dock" else int(r["page"])
        return (page_rank, int(r["row"] or 0), int(r["col"] or 0), r["pkg"])

    out_rows.sort(key=sort_key)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["page", "blob", "order", "col", "row", "pkg", "name", "note"],
                            delimiter="\t", lineterminator="\n")
        w.writeheader()
        for r in out_rows:
            w.writerow(r)

    print(f"Wrote {len(out_rows)} row(s) to {args.out}")
    if skipped:
        print(f"{len(skipped)} item(s) skipped:")
        for title, reason in skipped:
            print(f"  {title!r}: {reason}")


if __name__ == "__main__":
    main()
