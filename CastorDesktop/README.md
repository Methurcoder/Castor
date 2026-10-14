# CastorDesktop (Windows preview)

The Castor pet on Windows: a saved pet lives in a transparent, always-on-top window. It breathes, blinks, looks at your
pointer, and reacts when you move the pointer over its head.

Full Mac/Windows feature parity is in progress. A native PNG → marker review →
layered Standard/Quality creation flow is included, using the same extraction,
non-ML backing repair and depth construction as Mac. Windows replacements for Vision/Core ML,
conversation, voice, camera and the full settings UI remain unfinished. See the
[feature inventory and plan](../docs/CROSS_PLATFORM_PARITY.md).

The fixed Castor source passes a Windows x64 Swift 6.4.1 Release
build and 14 portable runtime tests at the first milestone. The next Quality/depth
playback milestone and current check results are tracked in the feature inventory. GUI interaction and real-pet
rendering remain unverified. Linux cross-build success was recorded before the Castor rename;
it has not been repeated after renaming. A non-Windows build does not exercise
the Win32 code.

| Action | How |
| --- | --- |
| Move the pet | Drag it |
| Pet it | Move the pointer back and forth over its head |
| Click what it covers | Hold Alt over it; it turns faint and lets clicks through |
| Quit | Right-click › Quit Castor |

## Windows verification report

The 2026-10-13–14 report tested the **old Pomegranate preview ZIP** on Windows
x64 with Swift 6.4.1, not the current Castor checkout. The original ZIP failed
to compile because a top-level variable using a private type lacked `private`,
and `GetMessageW` returned Swift `Bool` where the code called `.boolValue`.
A validation copy with those two lines corrected built successfully in Release.

Seven tests were reported as passing, but one returned without checking anything
because a saved pet was absent; six executed assertions. Synthetic archives
covered loading, alpha, deformation and invalid-data rejection. `pet-snapshot`
wrote four synthetic frames, and the user confirmed a red synthetic shape in
the corrected Debug app. These results do not establish real-character quality
or performance.

Dragging, right-click Quit and Alt click-through were not tested. No real pet
exported from a Mac was available, so breathing, blinking, gaze, petting and
`--wide-head` appearance remain unverified. The fixed Castor checkout now passes [Windows/macOS CI](https://github.com/Methurcoder/Castor/actions/runs/38424052817): seven runtime tests on both platforms and a Windows Win32 Release build. The old silent return has been replaced with a deterministic synthetic archive. Distribution checks pass 11 tests on macOS and eight on Windows; the three Mac-only launcher checks are explicitly skipped on Windows. A real-pet GUI check is still pending.

## Create a pet locally (in development)

Launch the built app without arguments. Choose one-image or front/profile Quality,
select PNG files, choose a subject when disconnected characters are detected, and
review the head/eye/mouth markers for each image. Creation uses the shared Mac
layer extraction, backing repair, motion bindings and Quality depth/pose sweep.
Progress windows support cancellation; saving starts only after a successful build.
Created pets use unique history files under `%LOCALAPPDATA%\Castor\Library`.

Face estimates use the shared illustration heuristic, with an explicitly unconfirmed
manual template fallback. Alpha or a uniform background can be separated; Windows
Vision/Core ML replacements and LaMa are not connected yet. Model-free construction
does not establish full automatic-rig quality on arbitrary images. Native UI, restart
and cross-platform GUI interaction remain unverified.

Right-click to create another Standard/Quality pet, open/export a pet, switch Quality
playback, or make a GIF. GIF creation offers motion, 3–5 seconds and background,
shows an animated preview, then saves and optionally opens X. Attach the saved GIF
manually in X; it is not uploaded/attached automatically. Desktop/camera/chat are
never captured. Real-image GIF quality and the Windows UI still need checking.

## Optional: import an existing Mac pet

Copy the Mac app's saved pet to the Windows PC:

```
~/Library/Containers/dev.pomegranate.prototype/Data/Library/Application Support/Castor/CastorPet.json
```

The bundle ID remains `dev.pomegranate.prototype` to keep the existing macOS
container and permissions. If you have not saved a pet with Castor yet, use the
old `Pomegranate/PomegranatePet.json` under the same Application Support folder.
Castor reads that old file as a fallback without deleting it.

(In Finder: Go › Go to Folder… and paste the folder path.) A bare single-view or two-view Quality
archive (`.arils`) also works. The pet must have been built with Arils, not
the legacy manual rig.

## Two-view Quality playback (in progress)

Saved Quality pets now retain both views, the declared profile direction, neck
registration and presentation mode. Gaze uses the same turn/pitch springs as the
Mac engine. Small turns use the front depth rig; supported larger turns blend to
the profile. The opposite direction never mirrors/reveals the profile. CPU depth
rendering uses the shared projection, layer bias and opaque/feather alpha passes.
Right-click a Quality pet to switch between 2D and 3D-plus-profile playback.
Export writes both views and the chosen mode; changing the mode alone currently
lasts for the session. Existing input files are not changed.

The native creation path now builds both views with the shared rigging backend.
Vision/Core ML replacements are still absent; arbitrary-image rig quality is unfinished. CPU texture reduction still differs from Metal's texture filtering.
Real-image CPU/Metal visual matching, performance, Windows menu/GUI and full
parity remain unverified. The Mac import UI accepts saved JSON; the bare Quality
export does not yet have a Mac import UI. Keep the original saved JSON for exchange.

## Developer-only: build on Windows

These compiler steps are for development. The planned end-user installer must not require them.

### Install Swift

From an elevated terminal, as on [swift.org](https://www.swift.org/install/windows/):

```
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
winget install --id Swift.Toolchain -e --source winget
```

Open a new terminal afterwards so `swift` is on the PATH.

### Build and run

Run this in **PowerShell** from the repository root. Replace the pet path with
your actual file. Build products go under `%TEMP%` to avoid a non-writable source
folder. Use `--show-bin-path` with the same configuration and scratch path;
Windows toolchains do not always put the executable in `.build\release`.

```powershell
Set-Location -LiteralPath 'CastorDesktop'
$castorBuildPath = Join-Path $env:TEMP 'Castor-preview-build'
swift build -c release --product CastorPet --scratch-path "$castorBuildPath"
if ($LASTEXITCODE -ne 0) { throw 'CastorPet build failed' }
$castorBinPath = ([string](swift build -c release --show-bin-path --scratch-path "$castorBuildPath" | Select-Object -Last 1)).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not locate the executable' }
& (Join-Path $castorBinPath 'CastorPet.exe') 'C:\path with spaces\CastorPet.json'
```

`Join-Path` and the call operator `&` handle executable paths containing spaces.
The quoted pet path is passed as one argument.

Without an argument it reloads the last selected library pet, then checks the
application data/current-folder legacy files, and otherwise offers local creation
or file selection. An explicit path to an old pet also works.
Add `--wide-head` to try the wider head movement beta (the head turns about
twice as far and the body follows; edges can show at the far end of a turn).

## Checking the runtime without Windows

Everything except the window is platform-independent (`PetRuntime`) and runs
on macOS and Linux too:

```
swift test
swift run -c release pet-snapshot CastorPet.json frame 260 340   # writes frame-0.ppm …
```

## Layout

- `PetRuntime` — loads the pet, runs Arils motion (`ArilsMotion`), deforms
  the rig (`ArilsPlayer`, the same evaluator and projection as the macOS
  Metal renderer), plays both Quality views via `PetPlayback`, and rasterizes into a premultiplied BGRA canvas on the CPU.
- `CastorPet` — the Win32 shell: a layered window updated with
  `UpdateLayeredWindow`, a 30 fps timer, drag, menu and Alt see-through.
- `CStbImage` — [stb_image](https://github.com/nothings/stb) v2.30
  (public domain / MIT) for PNG decoding.

## Windows conversation, settings and speech (implementation in progress)

The native menu now exposes local chat, model/personality selection, display preferences,
SAPI voices/reading, and microphone dictation with review before sending. Endpoints are
loopback-only; the same CastorCore LLM clients, structured reply fallback and model metadata
are used. Settings are kept outside executable versions and previous JSON is backed up.

Brain/routing can use existing Codex/Claude Code sessions. Operation details are shown
before per-request approval/rejection; cancelling releases pending approvals and interrupts
the turn. Agent services may transmit content to their configured provider, explained in
UI. Service authentication/helper GUI setup, camera and Neural TTS remain unfinished.
Native speech, actor/Win32 interaction, approvals and dialogs still require Windows checks.
