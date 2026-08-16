#!/usr/bin/env python3
"""Turn a layout tree (TSV, or a legacy markdown plan) into a real Lawnchair
.lawnchairbackup file — no root, no manual dragging.

A .lawnchairbackup is just a zip of:
  launcher.db                     sqlite db, single `favorites` table
                                   (container/screen/cellX/cellY/itemType/
                                   intent) — this IS the home screen layout.
  com.android.launcher3.prefs.xml, preferences, preferences.preferences_pb
                                   launcher settings, copied through as-is.
  info.pb, screenshot.png         header + cosmetic preview, copied as-is.

This script takes a REFERENCE backup (export one for real from Lawnchair
once — Settings > Backup > Export — so we have a valid template for the
non-layout files and the exact favorites schema/pragmas) and replaces its
favorites rows with ones generated from the layout tree:

  - Rows with page=dock -> the hotseat/dock row (container -101), frozen
    across every page. Dock supports folders too, same as a page: rows
    sharing a (dock, blob) group into one folder icon.
  - Rows with page=1,2,3... and no blob -> a plain top-level icon directly
    on that workspace screen (container -100, screen = page-1).
  - Rows sharing the same (page, blob) -> a folder icon on that page named
    `blob`; single-item groups collapse to a plain icon (no 1-item
    folders). Items inside a folder are laid out row-major in `order`.

Official input format — a TSV with columns:
    page    blob    order   pkg                 name            note
    dock            1       app.hiddify.com     Hiddify         VPN
    1               1       app.hiddify.com     Hiddify
    1       Social  1       com.vkontakte.android   VK
    1       Social  2       com.vk.vkvideo      VK Video

`page` is an integer, or the literal `dock`. `blob` empty = standalone icon.
`order` sorts items within their (page, blob) group and groups within a
page. `name`/`note` are for human review only, not read back. This is
meant to be the source of truth — edit it in a spreadsheet, regenerate the
backup any time. See templates/layout_example.tsv for a starter.

Legacy input: --plan accepts the older Page > Blob > Item markdown format
(layout_plan.md), where Page 1's leading bullet list (before the first
"### Blob:") is treated as the dock. Prefer --layout-tsv for anything you
intend to keep editing/versioning.

Component resolution: for a "perfect" restore (icon shows immediately, no
re-resolve flicker) each item's intent should point at the app's actual
launcher Activity, not just its package. If adb + a connected device are
available, this script resolves it live via
`adb shell cmd package resolve-activity`. Results are cached in
state/app_launch_activity.tsv (same sharing pattern as state/app_info.tsv)
so re-runs don't re-resolve. If adb/device isn't available, or resolution
fails for a package (not installed yet, e.g. mid-migration), it falls back
to a package-only intent — Android resolves that to the single matching
launcher Activity itself at tap time, so it still works, it's just not
pre-resolved.

Usage:
    python3 scripts/build_layout_backup.py \\
        --layout-tsv state/migration/<serial>_layout.tsv \\
        --reference "state/migration/<exported backup>.lawnchairbackup" \\
        --serial <serial> \\
        [--cols 5] [--rows 5] \\
        [--out state/migration/<serial>_generated.lawnchairbackup]

Then: adb push the output to /sdcard/Download/ and in Lawnchair, Settings >
Backup > Restore > pick it > Layout and settings.
"""
import argparse
import csv
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = REPO_ROOT / "state"
APP_INFO_FILE = STATE_DIR / "app_info.tsv"
LAUNCH_ACTIVITY_FILE = STATE_DIR / "app_launch_activity.tsv"

PAGE_RE = re.compile(r"^##\s+Page\s+(\d+)\b")
OTHER_H2_RE = re.compile(r"^##\s+(?!Page\s+\d)")
BLOB_RE = re.compile(r"^###\s+Blob:\s*(.+?)\s*$")
BULLET_RE = re.compile(r"^-\s+(\S+)")

# Both parsers produce this shape:
#   dock_groups: [(blob_name_or_None, [pkg, ...]), ...]   # dock supports
#                                                          # folders too
#   pages: {page_num: [(blob_name_or_None, [pkg, ...]), ...]}
# A group with blob_name=None always holds exactly one item (a standalone
# icon); a group with a real blob_name holds 1+ items (1 collapses to a
# plain icon at build time, same as a None group).


# --------------------------------------------------------------------
# 1a. Parse the official layout TSV
# --------------------------------------------------------------------

def parse_layout_tsv(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))

    def sort_key(i_r):
        i, r = i_r
        try:
            order = int((r.get("order") or "0").strip())
        except ValueError:
            order = 0
        return (order, i)

    rows = [r for _, r in sorted(enumerate(rows), key=sort_key)]

    # "dock" is just another container key alongside int page numbers —
    # it supports blob (folder) grouping exactly like a page does.
    containers = {}
    group_index = {}
    standalone_counter = 0

    for r in rows:
        pkg = (r.get("pkg") or "").strip()
        if not pkg:
            continue
        page_raw = (r.get("page") or "").strip()
        blob = (r.get("blob") or "").strip()

        if page_raw.lower() == "dock":
            key_page = "dock"
        else:
            try:
                key_page = int(page_raw)
            except ValueError:
                print(f"WARNING: skipping row with unrecognized page {page_raw!r} (pkg={pkg})")
                continue

        containers.setdefault(key_page, [])
        if blob:
            key = (key_page, blob)
        else:
            standalone_counter += 1
            key = (key_page, "__standalone__", standalone_counter)
        if key not in group_index:
            containers[key_page].append([blob or None, []])
            group_index[key] = len(containers[key_page]) - 1
        containers[key_page][group_index[key]][1].append(pkg)

    dock_groups = [(name, items) for name, items in containers.pop("dock", [])]
    pages = {p: [(name, items) for name, items in groups] for p, groups in containers.items()}
    return dock_groups, pages


# --------------------------------------------------------------------
# 1b. Legacy markdown parser (layout_plan.md) — dock has no folder
# support in this format, every dock row is its own standalone icon.
# --------------------------------------------------------------------

def parse_plan_markdown(path):
    dock_items = []
    pages = {}
    cur_page = None
    cur_blob = None
    in_pages_section = False

    for raw in Path(path).read_text().splitlines():
        m = PAGE_RE.match(raw)
        if m:
            cur_page = int(m.group(1))
            pages[cur_page] = []
            cur_blob = None
            in_pages_section = True
            continue
        if OTHER_H2_RE.match(raw):
            cur_page = None
            cur_blob = None
            in_pages_section = False
            continue
        if not in_pages_section or cur_page is None:
            continue

        m = BLOB_RE.match(raw)
        if m:
            cur_blob = [m.group(1), []]
            pages[cur_page].append(cur_blob)
            continue

        m = BULLET_RE.match(raw)
        if m:
            pkg = m.group(1)
            if cur_blob is not None:
                cur_blob[1].append(pkg)
            elif cur_page == 1:
                dock_items.append(pkg)

    for p in pages:
        pages[p] = [(name, items) for name, items in pages[p]]
    dock_groups = [(None, [pkg]) for pkg in dock_items]
    return dock_groups, pages


# --------------------------------------------------------------------
# 2. App name lookup (reuse the shared cache, purely cosmetic — folder/
#    item titles). Falls back to the raw package id.
# --------------------------------------------------------------------

def load_app_names():
    if not APP_INFO_FILE.exists():
        return {}
    with open(APP_INFO_FILE, newline="") as f:
        return {r["package"]: r.get("name", "") for r in csv.DictReader(f, delimiter="\t")}


# --------------------------------------------------------------------
# 3. Launcher-activity resolution (adb, cached)
# --------------------------------------------------------------------

def load_launch_activity_cache():
    if not LAUNCH_ACTIVITY_FILE.exists():
        return {}
    with open(LAUNCH_ACTIVITY_FILE, newline="") as f:
        return {r["package"]: r["activity"] for r in csv.DictReader(f, delimiter="\t") if r.get("activity")}


def save_launch_activity_cache(cache):
    LAUNCH_ACTIVITY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LAUNCH_ACTIVITY_FILE, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["package", "activity"], delimiter="\t")
        w.writeheader()
        for pkg, act in sorted(cache.items()):
            w.writerow({"package": pkg, "activity": act})


def resolve_activity(serial, pkg):
    """Returns 'pkg/Activity' or None if resolution failed (not
    installed, ambiguous, adb unavailable, etc.)."""
    try:
        out = subprocess.run(
            ["adb", "-s", serial, "shell", "cmd", "package", "resolve-activity",
             "--brief", "-c", "android.intent.category.LAUNCHER",
             "-a", "android.intent.action.MAIN", pkg],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None
    for line in out.splitlines():
        line = line.strip()
        if line and "/" in line and not line.startswith("No activity") and not line.startswith("priority"):
            return line
    return None


def build_intent(pkg, activity):
    """Intent#toUri(0)-style string, same format Launcher3 stores."""
    base = ("#Intent;action=android.intent.action.MAIN;"
            "category=android.intent.category.LAUNCHER;"
            "launchFlags=0x10200000;")
    if activity:
        return f"{base}component={activity};end"
    return f"{base}package={pkg};end"


# --------------------------------------------------------------------
# 4. Build the favorites rows
# --------------------------------------------------------------------

class RowBuilder:
    def __init__(self, names, activities, now_ms):
        self.rows = []
        self.next_id = 1
        self.names = names
        self.activities = activities
        self.now_ms = now_ms
        self.placed_packages = set()

    def label(self, pkg):
        return self.names.get(pkg, pkg)

    def new_id(self):
        i = self.next_id
        self.next_id += 1
        return i

    def add_app(self, pkg, container, screen, cell_x, cell_y, rank=0):
        if pkg in self.placed_packages:
            return False
        self.placed_packages.add(pkg)
        activity = self.activities.get(pkg)
        self.rows.append({
            "_id": self.new_id(), "title": self.label(pkg),
            "intent": build_intent(pkg, activity),
            "container": container, "screen": screen,
            "cellX": cell_x, "cellY": cell_y, "spanX": 1, "spanY": 1,
            "itemType": 0, "appWidgetId": -1, "icon": None,
            "appWidgetProvider": None, "modified": self.now_ms,
            "restored": 1, "profileId": 0, "rank": rank, "options": 0,
            "appWidgetSource": -1,
        })
        return True

    def add_folder(self, title, container, screen, cell_x, cell_y):
        folder_id = self.new_id()
        self.rows.append({
            "_id": folder_id, "title": title, "intent": None,
            "container": container, "screen": screen,
            "cellX": cell_x, "cellY": cell_y, "spanX": 1, "spanY": 1,
            "itemType": 2, "appWidgetId": -1, "icon": None,
            "appWidgetProvider": None, "modified": self.now_ms,
            "restored": 1, "profileId": 0, "rank": 0, "options": 0,
            "appWidgetSource": -1,
        })
        return folder_id

    def add_folder_item(self, pkg, folder_id, idx, folder_cols=4, folder_rows=4):
        if pkg in self.placed_packages:
            return False
        self.placed_packages.add(pkg)
        per_screen = folder_cols * folder_rows
        internal_screen = idx // per_screen
        pos = idx % per_screen
        activity = self.activities.get(pkg)
        self.rows.append({
            "_id": self.new_id(), "title": self.label(pkg),
            "intent": build_intent(pkg, activity),
            "container": folder_id, "screen": internal_screen,
            "cellX": pos % folder_cols, "cellY": pos // folder_cols,
            "spanX": 1, "spanY": 1, "itemType": 0, "appWidgetId": -1,
            "icon": None, "appWidgetProvider": None, "modified": self.now_ms,
            "restored": 1, "profileId": 0, "rank": idx, "options": 0,
            "appWidgetSource": -1,
        })
        return True


def place_groups(rb, groups, container, screen, cols, rows_cap, label):
    """Row-major placement of (blob_name_or_None, [pkgs]) groups into a
    cols x rows_cap grid on the given container/screen. Shared by both
    the dock (container -101, typically rows_cap=1) and workspace pages
    (container -100, one call per page) — a folder and a dock both just
    need "N group slots on a grid", the only difference is capacity."""
    warnings = []
    cell_idx = 0
    capacity = cols * rows_cap
    for blob_name, items in groups:
        items = [p for p in items if p not in rb.placed_packages]
        if not items:
            continue
        if cell_idx >= capacity:
            warnings.append(
                f"{label}: ran out of grid space ({cols}x{rows_cap}={capacity} cells) "
                f"before placing '{blob_name or items[0]}' — bump capacity or trim.")
            break
        cx, cy = cell_idx % cols, cell_idx // cols
        if len(items) == 1:
            rb.add_app(items[0], container, screen, cx, cy)
        else:
            folder_id = rb.add_folder(blob_name, container, screen, cx, cy)
            for i, pkg in enumerate(items):
                rb.add_folder_item(pkg, folder_id, i)
        cell_idx += 1
    return warnings


def build_favorites(dock_groups, pages, names, activities, cols, rows,
                     dock_cols=None, dock_rows=1):
    now_ms = int(time.time() * 1000)
    rb = RowBuilder(names, activities, now_ms)
    warnings = []

    d_cols = dock_cols if dock_cols is not None else max(1, len(dock_groups))
    warnings += place_groups(rb, dock_groups, container=-101, screen=0,
                              cols=d_cols, rows_cap=dock_rows, label="Dock")

    for page_num in sorted(pages):
        warnings += place_groups(rb, pages[page_num], container=-100, screen=page_num - 1,
                                  cols=cols, rows_cap=rows, label=f"Page {page_num}")

    return rb.rows, warnings


# --------------------------------------------------------------------
# 5. Write it all into a new .lawnchairbackup
# --------------------------------------------------------------------

FAVORITES_COLUMNS = [
    "_id", "title", "intent", "container", "screen", "cellX", "cellY",
    "spanX", "spanY", "itemType", "appWidgetId", "icon", "appWidgetProvider",
    "modified", "restored", "profileId", "rank", "options", "appWidgetSource",
]


def write_backup(reference_zip, rows, out_path, work_dir):
    work_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(reference_zip) as zf:
        zf.extractall(work_dir)

    db_path = work_dir / "launcher.db"
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("DELETE FROM favorites")
    placeholders = ",".join("?" for _ in FAVORITES_COLUMNS)
    cur.executemany(
        f"INSERT INTO favorites ({','.join(FAVORITES_COLUMNS)}) VALUES ({placeholders})",
        [tuple(r[c] for c in FAVORITES_COLUMNS) for r in rows],
    )
    con.commit()
    con.close()

    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(work_dir.iterdir()):
            zf.write(f, arcname=f.name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--layout-tsv", type=Path, help="Official page/blob/pkg TSV (recommended).")
    src.add_argument("--plan", type=Path, help="Legacy Page>Blob>Item markdown file.")
    ap.add_argument("--reference", required=True, type=Path,
                     help="A real .lawnchairbackup exported from the device once, "
                          "used as the template for prefs/schema.")
    ap.add_argument("--serial", default=None,
                     help="ADB serial, for live launcher-activity resolution. "
                          "Omit to skip resolution (falls back to package-only intents).")
    ap.add_argument("--cols", type=int, default=5, help="Workspace page grid columns.")
    ap.add_argument("--rows", type=int, default=5, help="Workspace page grid rows.")
    ap.add_argument("--dock-cols", type=int, default=None,
                     help="Dock/hotseat grid columns. Defaults to however many dock "
                          "groups (icons+folders) the layout has.")
    ap.add_argument("--dock-rows", type=int, default=1,
                     help="Dock/hotseat grid rows (most launchers support 1-2).")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()

    src_path = args.layout_tsv or args.plan
    if not src_path.exists():
        sys.exit(f"Layout file not found: {src_path}")
    if not args.reference.exists():
        sys.exit(f"Reference backup not found: {args.reference}")

    out_path = args.out or (STATE_DIR / "migration" / "generated.lawnchairbackup")

    if args.layout_tsv:
        dock_groups, pages = parse_layout_tsv(src_path)
    else:
        dock_groups, pages = parse_plan_markdown(src_path)

    all_pkgs = set()
    for _, items in dock_groups:
        all_pkgs.update(items)
    for groups in pages.values():
        for _, items in groups:
            all_pkgs.update(items)

    dock_item_count = sum(len(items) for _, items in dock_groups)
    print(f"Parsed {len(pages)} page(s), {len(dock_groups)} dock group(s) "
          f"({dock_item_count} app(s)), {len(all_pkgs)} unique package(s) from {src_path.name}")

    names = load_app_names()
    activities = load_launch_activity_cache()

    to_resolve = [p for p in sorted(all_pkgs) if p not in activities]
    if args.serial and to_resolve:
        print(f"Resolving launcher activity for {len(to_resolve)} package(s) via adb "
              f"(cached ones skipped)...")
        for i, pkg in enumerate(to_resolve, 1):
            act = resolve_activity(args.serial, pkg)
            activities[pkg] = act or ""
            if i % 20 == 0 or i == len(to_resolve):
                print(f"  {i}/{len(to_resolve)}")
        save_launch_activity_cache(activities)
    elif to_resolve:
        print(f"No --serial given (or adb unavailable) — {len(to_resolve)} package(s) "
              f"will use package-only intents (still works, just not pre-resolved).")

    activities = {k: v for k, v in activities.items() if v}

    rows, warnings = build_favorites(dock_groups, pages, names, activities,
                                      args.cols, args.rows, args.dock_cols, args.dock_rows)
    print(f"Built {len(rows)} favorites row(s).")
    for w in warnings:
        print(f"WARNING: {w}")

    unresolved = sorted(all_pkgs - set(activities.keys()))
    if unresolved:
        print(f"{len(unresolved)} package(s) using package-only intent (not pre-resolved, "
              f"still functional): {', '.join(unresolved[:10])}"
              f"{' ...' if len(unresolved) > 10 else ''}")

    work_dir = out_path.parent / (out_path.stem + "_work")
    if work_dir.exists():
        shutil.rmtree(work_dir)
    write_backup(args.reference, rows, out_path, work_dir)
    shutil.rmtree(work_dir)

    print(f"\nWrote {out_path}")
    print("Next: adb push it to the phone and restore in Lawnchair:")
    print(f'  adb -s {args.serial or "<serial>"} push "{out_path}" /sdcard/Download/')
    print("  On the phone: Lawnchair > Settings > Backup > Restore > pick the file > "
          "Layout and settings.")


if __name__ == "__main__":
    main()
