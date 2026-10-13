# Arils AI operations

Castor can ask Ollama, Codex, or Claude Code to propose face-marker corrections for an imported Arils image. AI output is always a proposal: the app validates it, shows it over the source image, and only builds the avatar after the user presses the approval-and-build button. The original manual marker editor remains available.

## Setup flow

Open `Setting with AI` beside `Rigging` in the main mode selector. Castor asks:

1. whether the avatar starts from one front image or front plus a three-quarter reference;
2. whether Ollama, Codex, or Claude Code reviews marker alignment;
3. whether the optional LaMa hidden-region repair should be used, while showing detected physical memory and explaining that it is not a free-memory benchmark;
4. whether the summary should be saved before opening Rigging.

The three-quarter choice prepares the existing Arils 2D Quality path. It does not merge the Standard and Quality formats. LaMa is also separate from alignment: it repairs hidden backing pixels after marker approval and falls back to deterministic Arils repair when unavailable.

## `POME_ARILS_FACE_LAYOUT_V1`

This is the first AI-specific operation contract. Castor creates an ephemeral `REQUEST.md` and `source.png` packet for Codex or Claude Code. Ollama receives the same instructions and PNG through its localhost chat API. The request includes the current automatic/manual layout as a starting point.

The agent must return one JSON object:

```json
{
  "operation": "POME_ARILS_FACE_LAYOUT_V1",
  "head": {"x": 0.20, "y": 0.08, "width": 0.60, "height": 0.62},
  "eye_left": {"x": 0.34, "y": 0.30, "width": 0.10, "height": 0.08},
  "eye_right": {"x": 0.56, "y": 0.30, "width": 0.10, "height": 0.08},
  "mouth": {"x": 0.43, "y": 0.50, "width": 0.14, "height": 0.08},
  "confidence": 0.82,
  "explanation": "Short user-facing explanation"
}
```

Coordinates use a top-left origin and are normalized to `0...1`. `eye_left` and `eye_right` mean viewer-left and viewer-right. Castor rejects non-finite or out-of-bounds rectangles, reversed eyes, facial features outside the head search area, and a mouth that is not below the eyes.

## Privacy and approval boundary

- Nothing is sent while running the setup wizard.
- Ollama remains on localhost and requires a selected vision-capable model.
- Codex and Claude Code require a separate send confirmation because their configured accounts may process the image externally. Their localhost bridge is only the transport boundary.
- Codex receives `source.png` as a `localImage` turn input. Claude Code reads it from the temporary review packet.
- Existing per-action approval cards remain active for any command, file-change, or extra-permission request.
- The temporary packet is removed when the turn finishes or is cancelled.
- Valid AI coordinates only update the visible sheet. Closing, cancelling, resetting, or reverting discards them. Building and saving require explicit user actions.

The operation intentionally cannot build an avatar, edit project files, or save a pet. Future AI operations should use a new versioned operation identifier and preserve the same proposal-validation-approval boundary.
