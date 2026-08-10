#!/usr/bin/env python3
"""
scripts/wizard.py — guided end-to-end setup: pick source/dest devices,
debloat the new phone, migrate apps over, set up Lawnchair.
Orchestrates the existing devices.sh / debloat.sh / migrate.sh scripts
rather than reimplementing their logic — this file is UI/sequencing,
they remain the source of truth for what actually happens to a
device. Run it via ./run.sh at the repo root (no args), not directly.

Every step is skippable. Nothing destructive runs without an explicit
yes from you first (dry-run before real debloat, selectable package
list before pulling/installing anything).
"""
import csv
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
STATE_DIR = REPO_ROOT / "state"
DEVICES_TSV = STATE_DIR / "devices.tsv"
TEMPLATES_DIR = REPO_ROOT / "templates"
CATALOGS_DIR = STATE_DIR / "catalogs"
MIGRATION_STATE = STATE_DIR / "migration"


# --------------------------------------------------------------------
# small terminal UI helpers — no third-party deps on purpose, so this
# runs anywhere python3 + adb do
# --------------------------------------------------------------------

def say(msg=""):
    print(msg)


def header(msg):
    print()
    print("=" * min(70, max(20, len(msg) + 4)))
    print(msg)
    print("=" * min(70, max(20, len(msg) + 4)))


def ask_yes_no(prompt, default=True):
    suffix = " [Y/n] " if default else " [y/N] "
    while True:
        ans = input(prompt + suffix).strip().lower()
        if not ans:
            return default
        if ans in ("y", "yes"):
            return True
        if ans in ("n", "no"):
            return False
        print("Please answer y or n.")


def ask_select(prompt, options, allow_skip=False, skip_label="skip"):
    """options: list of (display_string, value). Returns value or None if skipped."""
    if not options:
        return None
    print(prompt)
    for i, (label, _val) in enumerate(options, 1):
        print(f"  {i}) {label}")
    if allow_skip:
        print(f"  0) {skip_label}")
    while True:
        raw = input(f"Choice{' [0]' if allow_skip else ''}: ").strip()
        if allow_skip and raw in ("", "0"):
            return None
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return options[int(raw) - 1][1]
        print("Not a valid choice, try again.")


def ask_multiselect(prompt, options, default_selected):
    """
    options: list of dicts with at least {'label': str}. default_selected:
    set of indices (0-based) pre-selected. Returns the (possibly edited)
    set of selected indices. Toggle by typing numbers (space/comma
    separated), 'a' selects all, 'n' selects none, Enter confirms.
    """
    selected = set(default_selected)
    while True:
        print()
        print(prompt)
        for i, opt in enumerate(options):
            mark = "[x]" if i in selected else "[ ]"
            print(f"  {mark} {i + 1}) {opt['label']}")
        print(f"({len(selected)}/{len(options)} selected)")
        raw = input(
            "Toggle numbers (e.g. '3 7 12'), 'a'=all, 'n'=none, Enter=confirm: "
        ).strip().lower()
        if raw == "":
            return selected
        if raw == "a":
            selected = set(range(len(options)))
            continue
        if raw == "n":
            selected = set()
            continue
        for tok in raw.replace(",", " ").split():
            if tok.isdigit():
                idx = int(tok) - 1
                if 0 <= idx < len(options):
                    if idx in selected:
                        selected.discard(idx)
                    else:
                        selected.add(idx)


def run(cmd, check=False, capture=False):
    """Run a subprocess, streaming output by default. Returns CompletedProcess."""
    print(f"$ {' '.join(cmd)}")
    if capture:
        result = subprocess.run(cmd, capture_output=True, text=True)
    else:
        result = subprocess.run(cmd)
        result.stdout = None
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(cmd)}")
    return result


# --------------------------------------------------------------------
# app-name enrichment (Python port of migrate.sh's fetch_app_info /
# extract_og_title / extract_og_description — same fallback order:
# Play Store -> RuStore -> F-Droid API) used by the layout-plan step.
# Kept separate from migrate.sh's bash version rather than shelling
# out to it, since this runs concurrently over the whole
# installed-package list rather than migrate.sh's one-at-a-time
# migration_config.txt rows — but reads/writes the SAME cache file
# (state/app_info.tsv), so a package looked up once by either
# migrate.sh's `enrich` or this step is never re-fetched by the other.
# --------------------------------------------------------------------

APP_INFO_FILE = STATE_DIR / "app_info.tsv"
APP_INFO_FIELDS = ["package", "name", "description", "source", "fetched_at"]

_OG_TITLE_TAG_RE = re.compile(r'<meta[^>]*property="og:title"[^>]*>')
_OG_DESC_TAG_RE = re.compile(r'<meta[^>]*property="og:description"[^>]*>')
_CONTENT_ATTR_RE = re.compile(r'content="([^"]*)"')
_UA_HEADERS = {"User-Agent": "Mozilla/5.0"}


def _extract_meta(html, tag_re):
    tag = tag_re.search(html)
    if not tag:
        return ""
    content = _CONTENT_ATTR_RE.search(tag.group(0))
    return content.group(1) if content else ""


def _fetch_url_text(url, headers=None, timeout=8):
    try:
        req = urllib.request.Request(url, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="ignore")
    except (urllib.error.URLError, TimeoutError, OSError):
        return ""


def read_app_info_cache():
    if not APP_INFO_FILE.exists():
        return {}
    with open(APP_INFO_FILE, newline="") as f:
        return {r["package"]: r for r in csv.DictReader(f, delimiter="\t")}


def write_app_info_cache(cache):
    APP_INFO_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(APP_INFO_FILE, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=APP_INFO_FIELDS, delimiter="\t")
        w.writeheader()
        for pkg, row in sorted(cache.items()):
            w.writerow({k: row.get(k, "") for k in APP_INFO_FIELDS})


def fetch_app_info(pkg):
    """Real (name, description, source) for pkg, fetched fresh — no
    cache check here, that's the caller's job (fetch_app_names below).
    source is one of play/rustore/fdroid/none."""
    html = _fetch_url_text(
        f"https://play.google.com/store/apps/details?id={pkg}&hl=en", _UA_HEADERS)
    name = _extract_meta(html, _OG_TITLE_TAG_RE)
    if name:
        return name, _extract_meta(html, _OG_DESC_TAG_RE), "play"

    html = _fetch_url_text(f"https://www.rustore.ru/catalog/app/{pkg}", _UA_HEADERS)
    name = _extract_meta(html, _OG_TITLE_TAG_RE)
    if name:
        return name, _extract_meta(html, _OG_DESC_TAG_RE), "rustore"

    text = _fetch_url_text(f"https://f-droid.org/api/v1/packages/{pkg}")
    if text:
        try:
            data = json.loads(text)
            loc = data.get("localized", {})
            en = loc.get("en-US") or (next(iter(loc.values())) if loc else {})
            name = en.get("name", "")
            if name:
                return name, en.get("summary", ""), "fdroid"
        except (ValueError, StopIteration):
            pass
    return "", "", "none"


def fetch_app_name(pkg):
    """Back-compat single-value wrapper (name only, no caching)."""
    return fetch_app_info(pkg)[0]


def fetch_app_names(pkgs, workers=8, progress=True):
    """Resolve real names for a list of packages, consulting/populating
    the shared state/app_info.tsv cache first — packages already
    looked up by this or migrate.sh's `enrich` are free. Only
    uncached packages hit the network, concurrently. Returns
    {pkg: name_or_empty_string}."""
    cache = read_app_info_cache()
    results = {}
    to_fetch = []
    for p in pkgs:
        row = cache.get(p)
        if row is not None:
            results[p] = row.get("name", "")
        else:
            to_fetch.append(p)

    if progress and cache:
        say(f"  {len(pkgs) - len(to_fetch)}/{len(pkgs)} already cached from a previous run.")

    if not to_fetch:
        return results

    total = len(to_fetch)
    done = 0
    now = __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(fetch_app_info, p): p for p in to_fetch}
        for fut in as_completed(futures):
            pkg = futures[fut]
            try:
                name, description, source = fut.result()
            except Exception:
                name, description, source = "", "", "none"
            results[pkg] = name
            cache[pkg] = {"package": pkg, "name": name, "description": description,
                          "source": source, "fetched_at": now}
            done += 1
            if progress and (done % 10 == 0 or done == total):
                say(f"  looked up {done}/{total} app names...")

    write_app_info_cache(cache)
    return results


# --------------------------------------------------------------------
# adb helpers
# --------------------------------------------------------------------

def adb_connected_devices():
    """Returns list of (serial, model) for currently connected+authorized devices."""
    try:
        out = subprocess.run(["adb", "devices"], capture_output=True, text=True).stdout
    except FileNotFoundError:
        say("adb not found in PATH. Install Android platform-tools first.")
        sys.exit(1)
    serials = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    devices = []
    for s in serials:
        model = subprocess.run(
            ["adb", "-s", s, "shell", "getprop", "ro.product.model"],
            capture_output=True, text=True,
        ).stdout.strip()
        devices.append((s, model or "(unknown model)"))
    return devices




# --------------------------------------------------------------------
# devices.tsv read/write (same 5-column schema as devices.sh)
# --------------------------------------------------------------------

def read_devices():
    if not DEVICES_TSV.exists():
        return []
    with open(DEVICES_TSV, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def write_devices(rows):
    STATE_DIR.mkdir(exist_ok=True)
    with open(DEVICES_TSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["label", "serial", "model", "catalog", "role"],
                            delimiter="\t")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def upsert_device(label, serial, model, catalog="", role=""):
    rows = read_devices()
    # clear this role from any other row first (only one holder per role)
    if role:
        for r in rows:
            if r.get("role") == role and r["label"] != label:
                r["role"] = ""
    found = False
    for r in rows:
        if r["label"] == label or (serial and r["serial"] == serial):
            # only overwrite fields we were actually given a non-empty
            # value for — this call is also used to patch just the
            # catalog or just the role, and must not blank out an
            # already-known serial/model in that case
            r.update(label=label,
                      serial=serial or r.get("serial", ""),
                      model=model or r.get("model", ""),
                      catalog=catalog or r.get("catalog", ""),
                      role=role or r.get("role", ""))
            found = True
    if not found:
        rows.append({"label": label, "serial": serial, "model": model,
                      "catalog": catalog, "role": role})
    write_devices(rows)


ROLE_DESC = {"old": "SOURCE (old) phone", "new": "DESTINATION (new) phone"}


def pick_device(prompt, exclude_serial=None):
    devices = adb_connected_devices()
    if exclude_serial:
        devices = [(s, m) for s, m in devices if s != exclude_serial]
    if not devices:
        say("No (other) authorized ADB devices connected.")
        return None
    options = [(f"{model} ({serial})", (serial, model)) for serial, model in devices]
    return ask_select(prompt, options)


def resolve_serial(serial, role, exclude_serial=None):
    """
    Get a connected, validated serial for the given role, prompting/
    waiting as needed. The ADB serial itself is the device's identity
    — no separate user-chosen label. Two cases:
      1. `serial` is already known (picked earlier this session, or
         persisted in state/devices.tsv from a previous run) -> wait
         for it to show up in `adb devices` if it isn't right now
         (returns immediately if it's already connected).
      2. `serial` is None (never seen this session) -> detect which
         newly plugged-in device it is by diffing `adb devices`
         output before/after asking the user to connect it, then
         register it against this role.
    This works the same whether devices are connected one at a time
    or both at once — it just waits for whatever isn't there yet.
    """
    role_desc = ROLE_DESC.get(role, role)
    connected = lambda: [s for s, _ in adb_connected_devices() if s != exclude_serial]  # noqa: E731

    if serial:
        if serial in connected():
            return serial
        while True:
            input(f"Connect the {role_desc} ({serial}) now, unlock it, accept the USB "
                  f"debugging prompt if asked, then press Enter...")
            if serial in connected():
                return serial
            if not ask_yes_no("Still not detected — keep trying?", default=True):
                sys.exit(1)

    # never seen this device connected before — detect it by diffing device lists
    say(f"The {role_desc} hasn't been connected yet this session.")
    known_before = set(connected())
    while True:
        input(f"Connect the {role_desc} now, unlock it, accept the USB debugging prompt "
              f"if asked, then press Enter...")
        now = adb_connected_devices()
        new_ones = [(s, m) for s, m in now if s not in known_before and s != exclude_serial]
        if len(new_ones) == 1:
            new_serial, model = new_ones[0]
        elif len(new_ones) > 1:
            new_serial, model = ask_select("Multiple new devices detected — which one is it?",
                                            [(f"{m} ({s})", (s, m)) for s, m in new_ones])
        else:
            say("No new device detected.")
            if ask_yes_no("Pick manually from the currently connected list instead?", default=True):
                choice = pick_device(f"Select the {role_desc}:", exclude_serial=exclude_serial)
                if not choice:
                    continue
                new_serial, model = choice
            else:
                continue
        upsert_device(new_serial, new_serial, model, role=role)
        say(f"Using {new_serial} ({model}) as the {role_desc}.")
        return new_serial


# --------------------------------------------------------------------
# wizard steps
# --------------------------------------------------------------------

def step_pick_source_dest():
    header("1/8 — Pick destination device")
    say("Destination = the NEW phone you're setting up (this is also what gets debloated).")
    say("Source = the OLD phone you'd migrate apps FROM — only needed if you want that.")
    say("Devices are identified by their ADB serial — no need to name them.")
    say()

    devices = adb_connected_devices()
    if not devices:
        say("No authorized ADB devices connected. Connect at least the destination phone")
        say("(source can be connected later) and re-run ./run.sh.")
        sys.exit(1)

    say("Connected devices:")
    for s, m in devices:
        say(f"  - {m} ({s})")
    say()

    dest_serial, dest_model = pick_device("Which device is the DESTINATION (new phone)?")
    upsert_device(dest_serial, dest_serial, dest_model, role="new")
    say(f"Destination: {dest_model} ({dest_serial})")

    say()
    want_migrate = ask_yes_no(
        "Also migrate apps over from an old (source) device? (No if you're just "
        "debloating this phone.)", default=True)

    src_serial = None
    if want_migrate:
        remaining = [(s, m) for s, m in devices if s != dest_serial]
        if remaining:
            src_serial, src_model = pick_device("Which device is the SOURCE (old phone)?",
                                                 exclude_serial=dest_serial)
            upsert_device(src_serial, src_serial, src_model, role="old")
        else:
            say("Source phone not connected yet — that's fine, we'll detect it automatically")
            say("the moment it's needed: just plug it in when prompted.")

    return {"dest_serial": dest_serial, "src_serial": src_serial, "want_migrate": want_migrate}


def step_pick_template(dest_serial):
    header("2/8 — Debloat catalog template")
    templates = sorted(p.stem for p in TEMPLATES_DIR.glob("*.tsv")) if TEMPLATES_DIR.exists() else []
    if not templates:
        say("No templates found in templates/ — skipping debloat setup.")
        return None

    rows = read_devices()
    existing_catalog = next((r["catalog"] for r in rows if r["serial"] == dest_serial and r.get("catalog")), None)
    if existing_catalog and (REPO_ROOT / existing_catalog).exists():
        say(f"{dest_serial} already has a catalog: {existing_catalog}")
        if not ask_yes_no("Re-seed it from a template (overwrites any edits)?", default=False):
            return REPO_ROOT / existing_catalog

    options = [(f"{t}", t) for t in templates]
    choice = ask_select("Pick a catalog template for the destination device:", options,
                         allow_skip=True, skip_label="none, skip debloating")
    if not choice:
        return None

    STATE_DIR.mkdir(exist_ok=True)
    CATALOGS_DIR.mkdir(exist_ok=True)
    dest_catalog = CATALOGS_DIR / f"{dest_serial}.tsv"
    dest_catalog.write_text((TEMPLATES_DIR / f"{choice}.tsv").read_text())
    upsert_device(dest_serial, "", "", catalog=f"state/catalogs/{dest_serial}.tsv")
    say(f"Seeded state/catalogs/{dest_serial}.tsv from template '{choice}'.")
    return dest_catalog


def step_debloat(dest_serial):
    header("3/8 — 4/8 — Debloat")
    dest_serial = resolve_serial(dest_serial, "new")

    say("Dry run first (no changes made yet)...")
    run(["./scripts/debloat.sh", "status", dest_serial])

    if ask_yes_no("\nRun the real debloat now (apply the catalog to the device)?", default=True):
        run(["./scripts/debloat.sh", "apply", dest_serial])
    else:
        say("Skipped — nothing changed on the device.")


def step_migrate(src_serial, dest_serial, want_migrate):
    header("5/8 — Port apps from the old device?")
    if not want_migrate:
        say("Skipping — you said this run is debloat-only, no old device to port from.")
        return

    MIGRATION_STATE.mkdir(parents=True, exist_ok=True)

    say("\n-- scanning source device --")
    src_serial = resolve_serial(src_serial, "old")
    run(["./scripts/migrate.sh", "scan-old", src_serial], check=True)

    say("\n-- scanning destination device --")
    dest_serial = resolve_serial(dest_serial, "new")
    run(["./scripts/migrate.sh", "scan-new", dest_serial], check=True)

    run(["./scripts/migrate.sh", "plan"], check=True)

    if ask_yes_no("\nLook up real app names from public store listings (needs internet, "
                  "takes a bit)?", default=True):
        run(["./scripts/migrate.sh", "enrich"])

    config_path = MIGRATION_STATE / "migration_config.txt"
    rows = _parse_migration_config(config_path)
    if not rows:
        say("Nothing to port — source and destination already match.")
        return

    header("6/8 — Choose which apps to port")
    options = [
        {"label": f"{r['pkg']}" + (f"  —  {r['name']}" if r.get('name') else "") +
                  f"   [{r['source']}]"}
        for r in rows
    ]
    default_selected = {i for i, r in enumerate(rows) if r["action"] == "PORT"}
    chosen = ask_multiselect("Apps missing on the destination device:", options, default_selected)
    _rewrite_migration_config(config_path, rows, chosen)

    say(f"\n{len(chosen)} app(s) marked to port.")
    if not chosen:
        say("Nothing selected — skipping pull/install.")
        return

    say("\n-- pulling APKs from source --")
    src_serial = resolve_serial(src_serial, "old")
    run(["./scripts/migrate.sh", "pull", src_serial], check=True)

    say("\n-- installing on destination --")
    dest_serial = resolve_serial(dest_serial, "new")
    run(["./scripts/migrate.sh", "install", dest_serial], check=True)


def _parse_migration_config(path):
    """Very small parser matching migrate.sh's own printf-padded format."""
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split(None, 3)
        if len(parts) < 3:
            continue
        action, pkg, source = parts[0], parts[1], parts[2]
        rest = parts[3] if len(parts) > 3 else ""
        name = ""
        if rest.startswith('"'):
            end = rest.find('"', 1)
            if end != -1:
                name = rest[1:end]
        rows.append({"action": action, "pkg": pkg, "source": source, "name": name, "raw": line})
    return rows


def _rewrite_migration_config(path, rows, chosen_indices):
    lines = []
    for i, r in enumerate(rows):
        action = "PORT" if i in chosen_indices else "SKIP"
        # keep the original line's package/source/note, just flip the action word
        rest = r["raw"].split(None, 1)[1] if " " in r["raw"] else ""
        lines.append(f"{action:<10} {rest}")
    header_lines = [l for l in path.read_text().splitlines() if l.startswith("#")]
    path.write_text("\n".join(header_lines + lines) + "\n")


def step_lawnchair(dest_serial):
    header("7/8 — Lawnchair launcher")
    if not ask_yes_no("Set up Lawnchair as the home launcher on the destination device?",
                       default=False):
        return

    dest_serial = resolve_serial(dest_serial, "new")

    installed = subprocess.run(
        ["adb", "-s", dest_serial, "shell", "pm", "list", "packages", "app.lawnchair"],
        capture_output=True, text=True,
    ).stdout.strip()

    if not installed:
        say("Lawnchair isn't installed on the destination device.")
        say("Install it from RuStore/Aurora manually, then come back here.")
        run(["adb", "-s", dest_serial, "shell", "am", "start",
             "-a", "android.intent.action.VIEW",
             "-d", "market://details?id=app.lawnchair"])
        input("Press Enter once Lawnchair is installed...")

    say("Attempting to set Lawnchair as the default home app...")
    resolve = subprocess.run(
        ["adb", "-s", dest_serial, "shell", "cmd", "package", "resolve-activity",
         "--brief", "app.lawnchair"],
        capture_output=True, text=True,
    ).stdout.strip().splitlines()
    component = next((l for l in resolve if "/" in l and "app.lawnchair" in l), None)

    if component:
        result = run(["adb", "-s", dest_serial, "shell", "cmd", "package",
                      "set-home-activity", "--user", "0", component], capture=True)
        if result.returncode == 0:
            say(f"Set {component} as the default home app.")
        else:
            say("Automated set-home-activity failed (this can happen depending on Android "
                "version/OEM restrictions). Set it manually: Settings > Apps > Default "
                "apps > Home app > Lawnchair.")
    else:
        say("Couldn't resolve Lawnchair's launcher activity automatically. Set it manually: "
            "Settings > Apps > Default apps > Home app > Lawnchair.")


def step_layout_plan(dest_serial):
    header("8/8 — Home screen layout plan")
    if not ask_yes_no("Generate a draft layout plan (grouping apps into folders/pages) "
                       "for you to edit?", default=True):
        return

    dest_serial = resolve_serial(dest_serial, "new")

    installed = subprocess.run(
        ["adb", "-s", dest_serial, "shell", "pm", "list", "packages", "-3"],
        capture_output=True, text=True,
    ).stdout
    pkgs = sorted(l.replace("package:", "").strip() for l in installed.splitlines() if l.strip())

    names = {}
    if pkgs and ask_yes_no(
            f"\nLook up real app names for all {len(pkgs)} apps (Play Store/RuStore/"
            f"F-Droid, needs internet, takes a couple minutes)?", default=True):
        say(f"Looking up {len(pkgs)} app names...")
        names = fetch_app_names(pkgs)

    def label(pkg):
        name = names.get(pkg, "")
        return f"{pkg} — {name}" if name else pkg

    # Lawnchair's home screen is Page > Blob (a folder is a "blob" of
    # grouped items) > Item. We can't know your actual grid size or
    # real categories from here, so this is a starting scaffold, not a
    # real plan: apps sorted by resolved name (falls back to package
    # id) and chunked into blobs of BLOB_SIZE, BLOBS_PER_PAGE per page.
    # Cut/paste items between blobs/pages freely — see the file's own
    # header for the full disclaimer.
    BLOB_SIZE = 8
    BLOBS_PER_PAGE = 5
    ordered = sorted(pkgs, key=lambda p: (names.get(p) or p).lower())
    blobs = [ordered[i:i + BLOB_SIZE] for i in range(0, len(ordered), BLOB_SIZE)]

    plan_path = MIGRATION_STATE / f"{dest_serial}_layout_plan.md"
    plan_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# Home screen layout plan — {dest_serial}",
        "",
        "Structure: Page > Blob > Item, matching Lawnchair (a \"blob\" here is a folder —",
        "a group of items that collapses to one icon on the page). Rename/merge/split",
        "blobs, move items between them, reorder pages, delete anything you don't want",
        "on the home screen (it stays in the app drawer regardless) — this file is just",
        "a planning aid, nothing reads it back automatically, since actual icon",
        "placement can't be scripted without root (see README). The grouping below is",
        "an alphabetical starting scaffold, not real categories — reorganize freely.",
        "",
    ]
    for page_num, page_start in enumerate(range(0, len(blobs), BLOBS_PER_PAGE), start=1):
        page_blobs = blobs[page_start:page_start + BLOBS_PER_PAGE]
        lines.append(f"## Page {page_num}")
        lines.append("")
        for blob_num, blob_items in enumerate(page_blobs, start=1):
            lines.append(f"### Blob {page_start // BLOB_SIZE + blob_num}")
            lines.append("")
            lines += [f"- {label(p)}" for p in blob_items]
            lines.append("")
    plan_path.write_text("\n".join(lines).rstrip() + "\n")

    say(f"Wrote {plan_path.relative_to(REPO_ROOT)}")
    input("Edit it now if you like, then press Enter to continue...")

    say()
    say("Manual steps to actually apply the layout in Lawnchair (this part can't be")
    say("automated without root — see README for why):")
    say("  1. Open Lawnchair, arrange icons/folders per your edited plan.")
    say("  2. Once you're happy with it: Lawnchair Settings > Backup > Export, to save")
    say("     this layout as a real Lawnchair backup file you can restore from later")
    say("     (e.g. after a factory reset) without redoing the arrangement by hand.")


def main():
    os.chdir(REPO_ROOT)
    header("mobile-migration-tool — guided setup")
    say("Every step below asks before doing anything real. Ctrl-C anytime to bail out —")
    say("nothing here is one-shot-destructive; you can always re-run ./run.sh or the")
    say("individual scripts (see README) to pick up where you left off.")

    ctx = step_pick_source_dest()
    step_pick_template(ctx["dest_serial"])
    step_debloat(ctx["dest_serial"])
    step_migrate(ctx["src_serial"], ctx["dest_serial"], ctx["want_migrate"])
    step_lawnchair(ctx["dest_serial"])
    step_layout_plan(ctx["dest_serial"])

    header("Done")
    say("Re-run ./run.sh anytime to pick up where you left off, or use the individual")
    say("scripts directly for more control — see README.md.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nBailed out — nothing further was changed.")
        sys.exit(130)
