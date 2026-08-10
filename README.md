# mobile-migration-tool

ADB-based tooling to set up a phone from scratch: strip bloatware declaratively, and migrate apps over from an old device without needing both phones connected at once.

Built and verified against a Redmi 15C (HyperOS 2 / Android 15), but `debloat/packages.tsv` is plain data — adapt it for other devices by editing the catalog.

## debloat/ — declarative debloat reconciler

`packages.tsv` is the single source of truth: one row per package, with the state you want it in (`absent`, `disabled`, `keep`, or `optional`). `debloat.sh` reconciles the real device to match it, and is safe to re-run at any time — already-satisfied packages are no-ops, nothing gets uninstalled twice or errors out on a second pass.

```
./debloat/debloat.sh status <serial>   # dry run: compare catalog vs device, no changes
./debloat/debloat.sh apply <serial>    # reconcile device to match the catalog
./debloat/debloat.sh list [state]      # print the catalog, no device needed
```

Edit `packages.tsv` directly to change what happens on the next `apply` — flip a package's state, add a new one, whatever. It's a plain TSV (package, state, category, note), diffable and reviewable in a PR.

One behavior worth knowing: a chunk of HyperOS system apps refuse full removal (`pm uninstall` fails with `Failure [-1000]`) even though they're not documented as protected anywhere. Rather than hand-maintaining a list of which ones do this, `apply` just tries the uninstall, detects that specific failure pattern, and automatically falls back to `pm disable-user` — so the catalog only needs to say `absent`, not which mechanism achieves it.

`keep`-state packages get drift detection: if one goes missing (removed by an earlier mistake, a stray script, whatever), both `status` and `apply` flag it explicitly instead of staying silent.

## migrate/ — multipass app migration

Compares installed apps between an old and new device and proposes (or executes) a migration path per app, without requiring both phones connected simultaneously — each step reads/writes state under `./migration_state/`.

```
./migrate/migrate_apps.sh scan-old <old_serial>
./migrate/migrate_apps.sh scan-new <new_serial>
./migrate/migrate_apps.sh plan
./migrate/migrate_apps.sh enrich      # look up real app names from public store listings
# edit migration_state/migration_config.txt by hand: PORT or SKIP each app
./migrate/migrate_apps.sh pull <old_serial>
./migrate/migrate_apps.sh install <new_serial>
```

## Credits

The initial `packages.tsv` bloatware classification started from [matthieu-pierson/debloat-hyperos-adb](https://github.com/matthieu-pierson/debloat-hyperos-adb) (MIT licensed) and was substantially extended: device-specific corrections (package name casing bugs, protected-app behavior), ~50 additional packages researched individually for necessity, and a rework from imperative shell command lists into this declarative/idempotent format.
