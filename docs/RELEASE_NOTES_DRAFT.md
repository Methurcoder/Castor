# Castor release notes (draft)

Changes since the public `Pomegranate-release-v1.1` branch. The version name is still undecided. The source repository is
[Methurcoder/Castor](https://github.com/Methurcoder/Castor). Castor is the successor to Pomegranate,
prepared for a new repository under a different GitHub account.

## Project name and compatibility

- Rename the macOS app / Xcode project / scheme to `Castor`, shared package to
  `CastorCore`, desktop preview to `CastorDesktop`, and executable to `CastorPet`.
- New pet saves use `Castor/CastorPet.json`; the old
  `Pomegranate/PomegranatePet.json` remains a read fallback. On Windows, the
  default input tries `CastorPet.json` before `PomegranatePet.json`.
- Keep `dev.pomegranate.prototype` and existing `Pomegranate.*` settings keys
  for compatibility. Keep the independent Arils / Arils-ex / ScreenshotAnswer
  names and the original license notices.
- Rename verification is separate from the earlier 109 Core tests and macOS
  build. Windows GUI remains unverified. Linux cross-build success is from the
  pre-rename handoff; it has not been repeated after renaming.

## Windows preview fixes and app downloads

- Fix the private top-level PetWindow variable and Swift 6.4.1 WinSDK Bool handling
  reported in the original Pomegranate preview ZIP.
- Replace the saved-Mac-pet test's silent return with a synthetic archive that
  always checks drawing, transparent background and premultiplied alpha.
- Test bare, saved and Quality-front archive loading, opacity and pose changes.
- Add Windows CI that builds the actual Win32 Release executable.
- Add native download launchers selecting only the matching OS/CPU ZIP,
  checking SHA-256, installing in a new version folder and deleting temporary downloads.
  Apps and download manifests must first be prepared as a Release; none exists yet.
- Add a Windows launcher that lets the user select a Mac-built pet file.

## Pet GIF sharing (macOS)

- Add “GIFを作って投稿する” to Rigging and the floating pet context menu.
- Preview a 3–5 second animation, choose a background, then save the GIF and open X's composer.
- Explicitly state that the GIF is not automatically attached: the user attaches the saved file and publishes on X.
- Standard and Quality export through the same Metal draw path as the live pet; manual rigs use the existing SwiftUI renderer.
- Encode locally, automatically reduce resolution/frame rate to limit file size, and keep desktop/camera/chat content out of the export.
- Add sandbox access only for files explicitly chosen in the system file picker. No X API upload or credential storage.
- Compilation has been checked; actual GPU export, animated preview, sandboxed save and X attachment still need manual verification.

## Characters and setup

- Official characters and the Prototype shape character are removed; you bring
  your own illustration and Arils rigs it.
- Manual rigging (rig JSON) moved to Settings › General › Advanced, as a
  fallback for images automatic rigging cannot handle yet.
- Platform-independent logic now lives in `CastorCore`, the first step
  toward the Windows/Linux UI.

## Motion (Arils)

What you will see in the app:

- Blinks and gaze are coupled: gaze shifts often bring a blink, with
  microsaccades and glances, and schedules no longer depend on frame rate or
  pauses.
- Lip sync follows quiet voices (automatic gain).
- Occasional small actions: glances, weight shifts, sighs, and when bored, a
  yawn or dozing off that a voice interrupts.

New in the Arils API, not yet driven by the app:

- Personality presets (`standard`, `shy`, `lively`, `calm`, `clumsy`) shared by
  every motion layer: hesitation, reaction speed, sway, blink rate,
  fidgeting, shyness, expressiveness. The app uses `standard`.
- Conversational attitudes (`idle`, `listening`, `thinking`, `speaking`,
  `surprised`) that change posture and gaze with a hesitant, slightly awkward
  timing, a momentary `hesitation` input, small beat gestures while speaking,
  and back-channel nods to the listener's voice.
- A speech timeline analysed before playback that lines the mouth up with TTS
  audio and closes it on silence.
- `arils-motion-eval` measures motion naturalness (periodicity, blink
  statistics, saccades, lip-sync agreement, frame-rate invariance) against a
  recorded baseline.

## Rigging quality (Arils)

- Cut-outs of opaque illustrations follow the drawing instead of Vision's
  rounded blob: the white haze between strands of pale hair is removed, and
  desks, chairs and drop shadows next to the character are left out. This uses
  an optional anime character segmentation model (ISNet, Apache 2.0) exported
  locally; without it, Vision's mask is refined against the image colors.
- Eyes are cut to their eyelid shape (from the optional anime face landmark
  model, MIT) instead of a rectangle, so blinking no longer moves a box of
  skin, and fringe over the eyes stays put.
- The area revealed behind the head when it turns is filled from its
  surroundings rather than one flat color.
- Face review can use the anime face model in-process through Core ML.

## Local AI

- On-device chat tells the model it cannot operate the Mac, change files, run
  commands, or control apps, and must never claim it performed an action.
- Requests that appear to need an agent show a brief notice while the pet
  generates its reply: on-device mode is conversation only; actions can be
  requested with Codex / Claude Code. The conversation continues.
- The local model picker shows parameter counts from Ollama or LM Studio,
  falling back to a clearly marked estimate from the model name. Models below
  about 7B show a caution about accuracy and remain selectable. Parameter
  count is a rough guide, not a guarantee of response quality.

## Known limitations

- Turning the head can still show a seam beside hair ornaments or at the crown:
  the head is cut by a rectangle-like region. Part segmentation is the planned
  fix.
- The optional Core ML models are not in the repository; see the Arils README
  for the export commands. Without them Arils falls back to its previous
  estimators.
- Attitudes, hesitation, personality presets and speech timelines are in the
  Arils API only; wiring them into the app is next.
