# CastorDesktop (Windows preview)

The Castor pet on Windows: a pet built with Arils on a Mac lives in a
transparent, always-on-top window. It breathes, blinks, looks at your
pointer, and reacts when you move the pointer over its head.

This is the first step of the Windows version. Building a pet (automatic
rigging) still needs the Mac app, because it uses Apple's Vision and Core ML;
conversation, voice and camera come later. The current Castor source has not
yet been retested on Windows; GUI interaction and real-pet rendering remain
unverified. Linux cross-build success was recorded before the Castor rename;
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
`--wide-head` appearance remain unverified. A Windows build and runtime check
of the current Castor checkout is still pending.

## 1. Bring a pet from the Mac

Copy the Mac app's saved pet to the Windows PC:

```
~/Library/Containers/dev.pomegranate.prototype/Data/Library/Application Support/Castor/CastorPet.json
```

The bundle ID remains `dev.pomegranate.prototype` to keep the existing macOS
container and permissions. If you have not saved a pet with Castor yet, use the
old `Pomegranate/PomegranatePet.json` under the same Application Support folder.
Castor reads that old file as a fallback without deleting it.

(In Finder: Go › Go to Folder… and paste the folder path.) A bare Arils
archive (`.arils`) also works. The pet must have been built with Arils, not
the legacy manual rig.

## 2. Install Swift on Windows

From an elevated terminal, as on [swift.org](https://www.swift.org/install/windows/):

```
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
winget install --id Swift.Toolchain -e --source winget
```

Open a new terminal afterwards so `swift` is on the PATH.

## 3. Build and run

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

Without an argument it looks for `CastorPet.json` in the current folder, then
falls back to `PomegranatePet.json`. An explicit path to an old pet also works.
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
  Metal renderer) and rasterizes into a premultiplied BGRA canvas on the CPU.
- `CastorPet` — the Win32 shell: a layered window updated with
  `UpdateLayeredWindow`, a 30 fps timer, drag, menu and Alt see-through.
- `CStbImage` — [stb_image](https://github.com/nothings/stb) v2.30
  (public domain / MIT) for PNG decoding.
