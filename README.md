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

Requires `python3` (the wizard logic lives in `scripts/wizard.py`). Walks through, in order:

1. Pick source (old) and destination (new) device — from currently connected ADB devices, or register a label now and connect it later. Asks up front whether both phones will be connected at once, or one at a time, and adapts every later step to match.
2. Pick a debloat catalog template for the destination device (seeds `state/catalogs/<label>.tsv`, or reuses an existing one).
3. Dry-run debloat (`status`), then asks before applying for real.
4. Optionally port apps from the old device: scans both devices, plans the diff, optionally enriches app names from public store listings, then shows a selectable checklist to mark what to port before pulling/installing.
5. Optionally sets up Lawnchair as the home launcher.
6. Optionally drafts a home-screen layout plan (`state/migration/<label>_layout_plan.md`) for you to edit, then walks you through applying it for real in Lawnchair (arranging icons is manual — no API for that without root — but the wizard points you at Lawnchair's own Settings > Backup > Export so you don't have to redo it after a factory reset).

Ctrl-C at any point is safe — nothing is one-shot-destructive, and re-running `./run.sh` (or the advanced commands below) picks up from whatever state is already saved.

## Advanced/scripted workflow

### 0. One-time setup: `./run.sh devices init`

Detects connected ADB device(s), asks you to label each one, lets you pick a debloat catalog template to seed that device's own editable copy under `state/catalogs/<label>.tsv`, and optionally tags it as the `old` or `new` device for migration. From then on, every other command accepts that label instead of a raw serial — and if only one device is connected, or a role is set, you can skip the device arg entirely.

```
./run.sh devices init                     # detect + label + template + role
./run.sh devices list                     # show saved devices
./run.sh devices templates                # list available catalog templates
./run.sh devices forget <label>
./run.sh devices set-role <label> <old|new|none>   # change role without re-init
```

## `./run.sh debloat` — declarative debloat reconciler

Each device's catalog (`state/catalogs/<label>.tsv`, seeded from a `templates/*.tsv`) is the single source of truth: one row per package, with the state you want it in — `absent`, `disabled`, `keep`, or `optional`. `debloat` reconciles the real device to match it, and is safe to re-run at any time — already-satisfied packages are no-ops, nothing gets uninstalled twice or errors out on a second pass.

```
./run.sh debloat status [serial-or-label]   # dry run: compare catalog vs device, no changes
./run.sh debloat apply  [serial-or-label]   # reconcile device to match the catalog
./run.sh debloat list   [state]             # print the resolved catalog, no device needed
```

Edit a device's `state/catalogs/<label>.tsv` directly to change what happens on the next `apply` — flip a package's state, add a new one, whatever. It's a plain TSV (package, state, category, note), diffable and reviewable in a PR.

One behavior worth knowing: a chunk of HyperOS system apps refuse full removal (`pm uninstall` fails with `Failure [-1000]`) even though they're not documented as protected anywhere. Rather than hand-maintaining a list of which ones do this, `apply` just tries the uninstall, detects that specific failure pattern, and automatically falls back to `pm disable-user` — so the catalog only needs to say `absent`, not which mechanism achieves it.

`keep`-state packages get drift detection: if one goes missing (removed by an earlier mistake, a stray script, whatever), both `status` and `apply` flag it explicitly instead of staying silent.

### Adding a template for another device

Drop a new `packages.tsv`-formatted file at `templates/<name>.tsv` (same 4-column TSV: package, state, category, note) and commit it. It shows up automatically in `./run.sh devices templates` and as a pick-list option in `./run.sh devices init` — no code changes needed. `templates/redmi15c.tsv` is there now as the first one.

## `./run.sh migrate` — multipass app migration

Compares installed apps between an old and new device and proposes (or executes) a migration path per app, without requiring both phones connected simultaneously — each step reads/writes state under `state/migration/`.

```
./run.sh migrate scan-old [old_serial_or_label]   # omit if the device has role "old"
./run.sh migrate scan-new [new_serial_or_label]   # omit if the device has role "new"
./run.sh migrate plan
./run.sh migrate enrich      # look up real app names from public store listings
# edit state/migration/migration_config.txt by hand: PORT or SKIP each app
./run.sh migrate pull [old_serial_or_label]
./run.sh migrate install [new_serial_or_label]
```

## Layout

```
run.sh                          single entry point: wizard (no args) or devices|debloat|migrate
scripts/
  wizard.py                       guided wizard logic, invoked by run.sh
  devices.sh                      device label/role registry + catalog template picker
  debloat.sh                      declarative debloat reconciler
  migrate.sh                      multipass app migration
  lib/resolve_device.sh           shared device/catalog resolution, sourced by the above
templates/*.tsv                 debloat catalog templates, one per device model (versioned)
state/                          ALL generated/local files live here — gitignored, per-machine
  devices.tsv                     device registry: label, serial, model, catalog, role
  catalogs/<label>.tsv            per-device live catalog, seeded from a template at init
  migration/                      migrate.sh working files, incl. layout plans
```

## Credits

The initial `templates/redmi15c.tsv` bloatware classification started from [matthieu-pierson/debloat-hyperos-adb](https://github.com/matthieu-pierson/debloat-hyperos-adb) (MIT licensed) and was substantially extended: device-specific corrections (package name casing bugs, protected-app behavior), ~50 additional packages researched individually for necessity, and a rework from imperative shell command lists into this declarative/idempotent format.
