# mobile-migration-tool

ADB-based tooling to set up a phone from scratch: strip bloatware declaratively, and migrate apps over from an old device without needing both phones connected at once.

Single entry point: `./run.sh`.

- **Guided:** `./run.sh` (no args) — an interactive wizard that walks the whole flow end to end (device pickup, debloat, app porting, Lawnchair, layout plan) and asks before doing anything real.
- **Advanced/scripted:** `./run.sh devices|debloat|migrate <command> ...` for scripting, partial runs, or CI-style automation.

Both drive the exact same scripts under `scripts/`, so you can mix and match — e.g. run the wizard once, then fall back to `./run.sh debloat apply` by hand later.

## Guided setup: `./run.sh`

```
./run.sh
```

Requires `python3` (the wizard logic lives in `scripts/wizard.py`). Devices are identified by their ADB serial — nothing to name. Walks through, in order:

1. Pick the destination (new) device from currently connected ADB devices, then asks whether you're also migrating apps from an old device — say no here if this run is debloat-only and the rest of the flow skips the source device entirely. If yes and the source isn't connected yet, that's fine — the migration step just prompts you to plug it in when it's actually needed, and auto-detects which device it is. Works the same whether both phones are connected at once or one at a time.
2. Pick a debloat catalog template for the destination device (seeds `state/catalogs/<serial>.tsv`, or reuses an existing one).
3. Dry-run debloat (`status`), then asks before applying for real.
4. If you opted into migration: port apps from the old device — scans both devices, plans the diff, optionally enriches app names from public store listings, then shows a selectable checklist to mark what to port before pulling/installing.
5. Optionally sets up Lawnchair as the home launcher.
6. Optionally drafts a home-screen layout tree (`state/migration/<serial>_layout.tsv`) for you to edit in a spreadsheet, then walks you through turning it into a real Lawnchair backup with `build_layout_backup.py` — no manual icon-dragging required (see "Scripting the Lawnchair layout" below).

Ctrl-C at any point is safe — nothing is one-shot-destructive, and re-running `./run.sh` (or the advanced commands below) picks up from whatever state is already saved.

## Advanced/scripted workflow

### One-time setup: `./run.sh devices init`

Detects connected ADB device(s) (identified by their own serial — nothing to name), lets you pick a debloat catalog template to seed that device's own editable copy under `state/catalogs/<serial>.tsv`, and optionally tags it as the `old` or `new` device for migration. From then on, if only one device is connected, or a role is set, you can skip the device arg entirely; otherwise pass the serial directly.

```
./run.sh devices init                     # detect + template + role
./run.sh devices list                     # show saved devices
./run.sh devices templates                # list available catalog templates
./run.sh devices forget <serial>
./run.sh devices set-role <serial> <old|new|none>   # change role without re-init
```

## `./run.sh debloat` — declarative debloat reconciler

Each device's catalog (`state/catalogs/<serial>.tsv`, seeded from a `templates/*.tsv`) is the single source of truth: one row per package, with the state you want it in — `absent`, `disabled`, `keep`, or `optional`. `debloat` reconciles the real device to match it, and is safe to re-run at any time — already-satisfied packages are no-ops, nothing gets uninstalled twice or errors out on a second pass.

```
./run.sh debloat status [serial]   # dry run: compare catalog vs device, no changes
./run.sh debloat apply  [serial]   # reconcile device to match the catalog
./run.sh debloat list   [state]    # print the resolved catalog, no device needed
```

Edit a device's `state/catalogs/<serial>.tsv` directly to change what happens on the next `apply` — flip a package's state, add a new one, whatever. It's a plain TSV (package, state, category, note), diffable and reviewable in a PR.

One behavior worth knowing: a chunk of HyperOS system apps refuse full removal (`pm uninstall` fails with `Failure [-1000]`) even though they're not documented as protected anywhere. Rather than hand-maintaining a list of which ones do this, `apply` just tries the uninstall, detects that specific failure pattern, and automatically falls back to `pm disable-user` — so the catalog only needs to say `absent`, not which mechanism achieves it.

`keep`-state packages get drift detection: if one goes missing (removed by an earlier mistake, a stray script, whatever), both `status` and `apply` flag it explicitly instead of staying silent.

### Adding a template for another device

Drop a new `packages.tsv`-formatted file at `templates/<name>.tsv` (same 4-column TSV: package, state, category, note) and commit it. It shows up automatically in `./run.sh devices templates` and as a pick-list option in `./run.sh devices init` — no code changes needed. `templates/redmi15c.tsv` is there now as the first one.

## `./run.sh migrate` — multipass app migration

Compares installed apps between an old and new device and proposes (or executes) a migration path per app, without requiring both phones connected simultaneously — each step reads/writes state under `state/migration/`.

```
./run.sh migrate scan-old [old_serial]   # omit if the device has role "old"
./run.sh migrate scan-new [new_serial]   # omit if the device has role "new"
./run.sh migrate plan
./run.sh migrate enrich      # look up real app names from public store listings
# edit state/migration/migration_config.txt by hand: PORT or SKIP each app
./run.sh migrate pull [old_serial]
./run.sh migrate install [new_serial]
```

## Scripting the Lawnchair layout (no root, no manual dragging)

`.lawnchairbackup` files are just zips — a sqlite `favorites` table (the
actual layout: container/screen/cellX/cellY/itemType/intent) plus a few
settings files. `scripts/build_layout_backup.py` builds one directly from
`state/migration/<serial>_layout.tsv`, so you don't have to drag 200 apps
into folders by hand:

```
# one-time: export a real backup so we have a template for the non-layout
# files and the exact schema — Lawnchair > Settings > Backup > Export,
# then adb pull it (or just move the file) into state/migration/

python3 scripts/build_layout_backup.py \
    --layout-tsv state/migration/<serial>_layout.tsv \
    --reference "state/migration/<your exported backup>.lawnchairbackup" \
    --serial <serial> \
    --out state/migration/<serial>_generated.lawnchairbackup

adb -s <serial> push state/migration/<serial>_generated.lawnchairbackup /sdcard/Download/
# on the phone: Lawnchair > Settings > Backup > Restore > pick the file > Layout and settings
```

`<serial>_layout.tsv` is the only input format and the official,
git-tracked source of truth (unlike the rest of `state/`, which is
gitignored) — columns `page, blob, order, col, row, pkg, name, note`.
`page` is a page number or the literal `dock`; `blob` groups rows into a
folder (empty = standalone icon); `order` controls placement within a
group and group order on the page. `col`/`row` are optional — set them
on any row of a group to pin that folder/icon to an exact grid cell
(0-indexed), matching a real screenshot's layout; leave blank and it
auto-fills the remaining free cells. The dock supports folders too, same
as a page — group several apps under one dock blob to fit more than
one-icon-per-slot. Open the TSV in any spreadsheet app (Excel/Numbers/
Sheets all read tab-separated files fine) to review/reorder, then
regenerate the backup any time. `--serial` resolves each app's actual
launcher Activity via adb for a clean, pre-resolved icon (cached in
`state/app_launch_activity.tsv`); without it, items still work, just via
a package-only intent Android resolves at tap time. `--cols`/`--rows`
(default 5x5) control the per-page grid; `--dock-cols`/`--dock-rows`
(default: fit / 1) control the dock — it'll warn instead of silently
overlapping if something doesn't fit.

## Layout

```
run.sh                          single entry point: wizard (no args) or devices|debloat|migrate
scripts/
  wizard.py                       guided wizard logic, invoked by run.sh
  devices.sh                      device label/role registry + catalog template picker
  debloat.sh                      declarative debloat reconciler
  migrate.sh                      multipass app migration
  build_layout_backup.py          scripts a .lawnchairbackup from <serial>_layout.tsv (no root)
  lib/resolve_device.sh           shared device/catalog resolution, sourced by the above
templates/*.tsv                 debloat catalog templates, one per device model (versioned)
state/                          ALL generated/local files live here — gitignored except as noted
  devices.tsv                     device registry, keyed by ADB serial: serial, model, catalog, role
  catalogs/<serial>.tsv           per-device live catalog, seeded from a template at init
  app_info.tsv                    shared cache: package -> real app name/description/source (migrate.sh enrich + wizard.py layout planner)
  app_launch_activity.tsv         shared cache: package -> resolved launcher Activity (build_layout_backup.py)
  migration/                      migrate.sh + layout tooling working files
    migration_config.txt            per-app PORT/SKIP decisions, hand-edited between `migrate.sh plan` and `pull`
    old_packages.tsv                scan-old output
    new_packages.txt                scan-new output
    apk_transfer/                   pulled APKs staged for install (large; safe to delete and re-pull)
    <serial>_layout.tsv             curated home-screen layout tree — the one file under state/ that IS git-tracked
    <serial>_reference.lawnchairbackup   a real exported Lawnchair backup, used as the schema/settings template by build_layout_backup.py
    <serial>_generated.lawnchairbackup   build_layout_backup.py output, ready to adb push + restore (regenerate any time, not tracked)
```

## Credits

The initial `templates/redmi15c.tsv` bloatware classification started from [matthieu-pierson/debloat-hyperos-adb](https://github.com/matthieu-pierson/debloat-hyperos-adb) (MIT licensed) and was substantially extended: device-specific corrections (package name casing bugs, protected-app behavior), ~50 additional packages researched individually for necessity, and a rework from imperative shell command lists into this declarative/idempotent format.
