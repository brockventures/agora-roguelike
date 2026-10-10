# Steam integration (#27, Integrate godot-steam SDK; part of #26, Epic 5)

The Steam layer is fully optional. The game runs, and every test passes, with no Steam client, no GodotSteam binary and no App ID of our own. When Steam is absent each call is a logged no-op.

## Status and the App ID dependency

- **App ID is 480 (Spacewar), Valve's public dev test app.** It lives in one place, `game/data/steam.json`, and can be overridden per run with `AGORA_STEAM_APP_ID`.
- **TODO, blocked on #30 (Steamworks onboarding, a human step under Mike's account):** put the real App ID in `steam.json`, rename `game/steam/game_actions_480.vdf` to `game_actions_<appid>.vdf` (`tests/test_steam_files.py` enforces the name), and create the achievements and stats below in the Steamworks partner site.
- **GodotSteam is not vendored.** Nothing in the repo needs the binary; add it per "Adding GodotSteam" when you want to test against real Steam.

## Pieces

| File | Role |
|---|---|
| `game/core/steam_service.gd` | `SteamService`: runtime detection (`Engine.has_singleton("Steam")`, `ClassDB`), every call through dynamic `.call()` so nothing fails to parse without the extension. Achievements, stats, local mirror, cloud helpers, Steam Input polling. |
| `game/core/steam_hooks.gd` | `SteamHooks`: connects `RunController` and `CrisisDeck` signals to the service. `Main` binds it to each new run. |
| `game/core/steam_hub.gd` | Autoload `SteamHub`: initialises the service, pumps callbacks, turns Steam Input edges into `InputEventAction`. Named `SteamHub`, not `Steam`, because `Steam` is GodotSteam's own singleton name. |
| `game/data/steam.json`, `game/data/achievements.json` | App ID; achievement and stat definitions. |
| `game/steam/` | Steam Input action manifest and default Steam Deck layout. |

## Achievements and stats

Defined in `game/data/achievements.json`. The achievement id doubles as the Steamworks API name; stat ids are the Steamworks stat API names (all `int`).

| Hook (real game event) | Effect |
|---|---|
| `RunController.bankruptcy_filed` | unlock `FIRST_CHAPTER_11`; stat `bankruptcies_filed` |
| `RunController.run_collapsed` | unlock `WITNESS_COLLAPSE` |
| `corp_ended`, `round_advanced` | stat `peak_net_worth` (max), `runs_completed` |
| `CrisisDeck.crisis_expired` | stat `crises_survived` + 1 |
| stat thresholds | `SERIAL_FILER` (5 filings), `NET_WORTH_25K/100K/1M`, `CRISIS_FIRST/10/25` unlock automatically from the stat |

Every unlock and stat is also written to a **local mirror** (`user://saves/steam_mirror.json`, through `SaveStore`). Offline progress is pushed to Steam the next time Steam is available; merging is union for unlocks and max for stats, so it never loses progress. `name` and `desc` in the JSON are the English text to paste into the partner site (Steam displays them, the game does not).

## Cloud saves

`SaveStore.cloud` (set by `Main.enable_persistence`) mirrors each successful write into Steam Remote Storage under the bare file name (`profile.json`, `settings.json`, `run_slot_0.json`, `steam_mirror.json`), and before each read pulls a Cloud copy down when it is newer than the local file or the local one is missing. The local file stays the source of truth, goes through the same schema validation, and the save format is unchanged. With Steam unavailable `SaveStore` behaves exactly as before.

Partner site setup (needs #30): Application, Cloud, enable Steam Cloud, set a byte quota of at least 1 MB and a file count of at least 8, and add the file names above. Because we write through the API there is no Auto-Cloud root path to configure. If you prefer Auto-Cloud instead, root `WinAppDataRoaming` (or `LinuxXdgDataHome`) with path `Godot/app_userdata/AGORA Roguelike/saves` and pattern `*.json`; do not enable both.

## Steam Deck input

`game/steam/game_actions_480.vdf` is the Steam Input action manifest: one action set `InGame` with a digital action per `m0_*` InputMap action (17, kept in step with `project.godot` by `tests/test_steam_files.py`). `controller_steamdeck_default.vdf` is the default layout: A confirm, B cancel, X Chapter 11, Y speed, D-pad or left stick move, right stick X cycles commodity, triggers cycle station, bumpers cycle tab, Start pause, View settings. These match the existing joypad bindings in `project.godot`.

At run time `SteamHub` calls `input_init()` and each frame `poll_input()`; edges become `InputEventAction` for the InputMap names, so `Main`, `SettingsMenu` remapping and every test see the same actions as before. Without Steam, Godot's own joypad bindings are used unchanged.

Shipping: Steam looks for `game_actions_<appid>.vdf` next to the executable (the depot root), and the default layout is uploaded in Steamworks, Steam Input, Edit Steam Input Configuration. Neither is done by `release.yml` yet.

## Adding GodotSteam

1. Download the GodotSteam GDExtension build matching the engine (4.7.x) from the GodotSteam releases page; check that a 4.7 build exists first.
2. Unpack into `game/addons/godotsteam/` (it brings its own `.gdextension`). Keep it out of the repo unless a 4.7 release is small and licence-checked.
3. For local runs outside the Steam client, Steam must be running and signed in. `SteamService.initialize()` sets `SteamAppId` itself; no `steam_appid.txt` is needed.
4. Run the game. The log shows `steam initialised (app 480)`; unlocks then appear in the Steam overlay.

## Not verified

The code was run only against `game/tests/steam_fake.gd`, which mimics the GodotSteam method names and return shapes from its documentation. It has not run against a real GodotSteam build or Steam client. Specifically unverified: the `steamInitEx` status codes, `fileRead` return shape, and the hand-written layout VDF (re-export it from Steam's configurator before shipping).
