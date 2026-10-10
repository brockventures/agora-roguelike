# Cutting a release

Releases are built by `.github/workflows/release.yml` (#28, multi-platform export pipeline; part of #26, Epic 5 Steamworks Integration & Automated Release Pipeline).

## Cut one

```
git checkout main && git pull
git tag v0.1.0          # semver; the tag minus the leading "v" becomes the game version
git push origin v0.1.0
```

The workflow then:

1. Runs the headless Godot suite and the preset guard test. If either fails, nothing is exported or published.
2. For each preset (`Linux x86_64`, `Windows Desktop`, `Steam Deck`), stamps the version into `application/config/version` (`tools/stamp_version.py`), and exports with `--headless --export-release`.
3. Copies `game/steam/game_actions_<appid>.vdf` (App ID from `game/data/steam.json`) into each `build/<dir>/` so Steam Input finds it beside the executable (see `docs/steam.md`; the default Deck layout is uploaded in Steamworks instead and is not shipped). Then zips each export as `agora-roguelike-<version>-<slug>.zip` with a `.sha256` beside it (slugs: `linux-x86_64`, `windows-x86_64`, `steamdeck`).
4. Attaches all of them to a GitHub Release for the tag, with generated notes.

A tag with a hyphen (for example `v0.1.0-rc.1`) works the same and is stamped as `0.1.0-rc.1`.

## Dry run

Actions, "Release", "Run workflow" (`workflow_dispatch`). It does everything except publish: the zips are run artifacts only, stamped `0.0.0-dev.<run number>`.

## Presets

`game/export_presets.cfg` holds the three presets. Output goes to `build/<platform>/` (gitignored). Tests (`tests/*`) and `tools/*` are excluded from every export. No code signing; Windows sets `application/modify_resources=false` so the Linux runner needs neither rcedit nor wine.

`Steam Deck` is a Linux x86_64 build with the PCK embedded in the binary (one file to ship as a Steam depot) and the feature tag `steamdeck`, so code can branch with `OS.has_feature("steamdeck")`. The `Linux x86_64` preset keeps a separate `.pck`.

`tests/test_export_presets.py` guards the preset names, platforms, exclusions, that the workflow exports each one, and that it copies the Steam Input manifest (the copy script is run against a fake build dir). Change a preset name and you must change the workflow matrix too.

## Bumping Godot

Update `GODOT_VERSION`, `GODOT_SHA512` and `TEMPLATES_SHA512` (from the release's `SHA512-SUMS.txt`) and `TEMPLATES_DIR` (version with `-` as `.`, e.g. `4.8.0.stable`) in `release.yml`, and `godot.yml` for the first two.

## Not covered yet

macOS export, code signing, and the Steamworks depot upload (rest of #26, Epic 5).

## Exporting locally

Download `Godot_v<version>_export_templates.tpz` from the Godot release, check it against `SHA512-SUMS.txt`, unzip it, and move the contents of its `templates/` folder to `~/.local/share/godot/export_templates/4.7.2.stable/`. Then `godot --headless --path game --export-release "Steam Deck"` writes to `build/steamdeck/`. Do not commit the stamped `project.godot`.
