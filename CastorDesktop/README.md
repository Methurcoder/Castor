# CastorDesktop (Windows preview)

The Castor pet on Windows: a pet built with Arils on a Mac lives in a
transparent, always-on-top window. It breathes, blinks, looks at your
pointer, and reacts when you move the pointer over its head.

This is the first step of the Windows version. Building a pet (automatic
rigging) still needs the Mac app, because it uses Apple's Vision and Core ML;
conversation, voice and camera come later. The Win32 window, input and
rendering are still awaiting a Windows hardware check. Linux cross-build
success was recorded before the Castor rename; it has not been repeated after
renaming. A non-Windows build does not exercise the Win32 code.

| Action | How |
| --- | --- |
| Move the pet | Drag it |
| Pet it | Move the pointer back and forth over its head |
| Click what it covers | Hold Alt over it; it turns faint and lets clicks through |
| Quit | Right-click › Quit Castor |

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

From the repository root:

```
cd CastorDesktop
swift build -c release --product CastorPet
.build\release\CastorPet.exe C:\path\to\CastorPet.json
```

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
