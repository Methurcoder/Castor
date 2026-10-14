# Castor release notes (draft)

Changes since the public `Pomegranate-release-v1.1` branch. The local candidate version is `v0.3.0-beta.1`; no app Release has been published. The source repository is
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

## Start Codex and Claude Code without Terminal (macOS)

- `Settings > Brain` now has `Start Codex with Castor` and `Start the Claude
  Code bridge with Castor`. A bundled, unsandboxed helper
  (`CastorAgentLauncher.app` in `Contents/Library/Helpers`) runs
  `codex app-server` and `claude_code_bridge.py` while Castor is open and
  stops them when Castor quits. The sandboxed app cannot run them itself,
  because child processes inherit the sandbox and cannot read the CLIs'
  configuration or login.
- The helper finds the CLIs through the login shell's PATH plus common
  install folders, refuses any address other than 127.0.0.1 / localhost,
  skips a service already listening on its port, and reports its state to
  Castor through a status file in Castor's container. The disclosure for each
  service is unchanged and is still required before it starts.
- Installing and signing in to the Codex CLI and Claude Code is still done
  with each service's own instructions. The Claude Code bridge also needs
  Python 3 (Command Line Tools).
- Qwen 3 TTS now has a bundled GUI helper: start, stop, prepare the model and cancel
  from Voice settings without installing Python or typing commands. Model weights
  are downloaded only after an explicit preparation action. Other optional helper
  installation and full Mac/Windows parity remain separate unfinished work.

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

- Add “GIFを作ってXで共有” to Rigging and the floating pet context menu.
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
- The four compiled Core ML models are not stored in Git. The Mac distribution
  builder and packager now require all four complete models and stop if one is
  missing. Plain developer builds may still use older fallback estimators; that
  fallback is not accepted for a distribution candidate.
- Attitudes, hesitation, personality presets and speech timelines are in the
  Arils API only; wiring them into the app is next.

## Pre-release audit corrections

- Document the lack of automatically added quarantine / Mark of the Web on script-fetched apps,
  the trust limits of the same-Release SHA-256 manifest, and first-run launcher warnings.
- Stage Windows downloads under LocalApplicationData/Programs/Castor on the install volume;
  suppress PowerShell 5.1 progress overhead and restrict authentication hints to relevant failures.
- Restrict Mac curl redirects to HTTPS.
- Use managed Metal output textures with GPU-to-CPU synchronization on dedicated-memory GPUs.
- Show neutral status for an explicit GIF cancellation, silently invalidate obsolete jobs,
  and prepare an opt-in repository URL for builds made after public release.
- The owner confirmed two-factor authentication is enabled; real Intel/Windows GUI checks are still pending.
- Enabled GitHub immutable releases for future releases. The source repository is public; app distribution Releases are still being prepared.
- Fixed Intel compilation of float16 Core ML outputs using Core ML numeric subscripts;
  Apple Silicon retains its direct Float16 conversion path.

### Audit correction verification (2026-10-14)

- Universal macOS Release build succeeded with arm64 and x86_64 slices. Code signing was
  disabled for this compilation check; the result is not a signed distribution package.
- Bash syntax, PowerShell parser checks and `git diff --check` passed.
- Existing downloader fixtures now refer to the new install root. No test cases were added
  or executed locally for this correction.
- Dedicated-memory Intel GIF rendering, first-run OS prompts, Windows PowerShell 5.1
  downloads/install and GUI interactions still need checks on their target systems.

## Source publication (2026-10-14)

- Publish the audited source with the owner's authorization and confirmed two-factor authentication.
- Update setup documentation for public access; no binary Release has been created.
- Enable the repository URL in the GIF sharing Web Intent for public builds.

## Mac / Windows parity: initial implementation

- Record the full feature-parity and no-command installation contract in CROSS_PLATFORM_PARITY.md.
- Start native Windows PNG selection, template marker editing, portable 2D keyform creation,
  saved-pet history/restart, existing-pet selection and Arils export.
- Add a Mac saved-pet JSON import action, validating archives and keeping the old pet as a backup.
- The native Windows UI and cross-platform GUI workflow are unverified. This prototype is not
  Mac-quality automatic depth/Quality rigging and does not complete the parity contract.
- Distribution entry is GitHub Releases, as confirmed by the user. GUI installer and complete
  runtime/model packaging remain in progress; no distribution Release is created by this change.

## Portable Quality playback and depth rendering

- Move Quality archives, legacy decoding, view-turn springs and neck registration math into ArilsPlayer;
  the Mac API re-exports the same types and keys.
- Retain front/profile views when loading JSON or bare Quality archives on Windows. Honor the
  saved mode, supported side and validated pose limits; right-click switches 2D/hybrid playback.
- Export both views and the chosen mode. A mode switch alone is session-local; complete settings
  persistence and Windows Quality creation are still unfinished.
- Add CPU opaque/feather depth passes, draw-order bias, transparent vertical gutters and single
  triangle-edge coverage. Whole-pet opacity no longer changes depth classification.
- CPU texture filtering and real-image CPU/Metal appearance still need parity work. GUI checks,
  Windows Quality rig construction and the remaining conversation/input/installer features are pending.

## 一括作業の追加実装（配布前・未検証を含む）

- GUIインストーラーの取得・更新・修復・削除と、失敗/取消時の旧版保持。
- Mac/Windows設定の日英表示、OS言語からの初期選択とGeneralの言語変更。
- Mac初回マイク許可と許可後の自動オン、拒否時の設定案内。明示オフを保持。
- Windowsローカル音量反応・初回案内・入力中表示・拒否時設定案内、矩形/ボタン種類だけによる退避。
- AI設定の任意姿勢補助: Codex接続の画像生成能力確認と本人の画像送信/採用、外部生成用prompt、
  生成画像の再読込。元画像を保持してRiggingへ引き継ぐ。姿勢の自動判定/リグの直立化は未実装。
- 「Ollama / LM Studio」へ案内変更し、LM Studioの画像対応モデル/提案へ接続。
- これらは全機能parityの完成版Releaseではない。Windows実機・実生成・正式署名/公証を継続確認する。

## 配布候補の状態（2026-10-15）

候補名は `v0.3.0-beta.1`。まだタグ・Draft・公開Releaseを作成していません。
UI刷新は後回しとし、既存UIのままQwen 3 TTSと配布前監査への対応を優先しています。

- Mac候補はApple Silicon向け。本体内にGUI Setup、native Qwen helper、必須4モデルを同梱。
  Intel版のコンパイル記録はありますが、今回のQwen同梱候補にはIntel版を含めません。
- Mac Qwen helperのGUIからモデル準備と日本語音声生成を確認し、3.12秒のWAVをOSで再生。
  この確認では既存モデルキャッシュを使用。新規ダウンロード・長文品質・本体Voice画面は未確認。
- Windows x64の通常CIとQwen同梱候補jobは成功（run 38599469990、commit 1a1566d）。
  同OSで梱包し、開発用PATHを除いた依存読込も成功。実機GUI・実モデル生成・
  スピーカー出力の確認とは区別します。macOS hosted jobはqueuedで、Macは下記ローカル確認です。
- 両OSのinstallerは日英表示と対象別の削除確認を追加。Macのquarantineと初回の
  「システム設定 › プライバシーとセキュリティ › このまま開く」の案内を維持。
- 更新時はcurrentとpreviousを保持し、指紋が一致する管理済み旧版だけをごみ箱へ送る。
  変更済み・個人ファイル追加済み・旧指紋なしのフォルダは自動整理しません。
- Mac配布候補のdebug情報から開発者home pathを除去し、検査を追加。
  この既知パターン検査は包括的な個人情報・秘密情報監査ではありません。
- Macはad-hoc署名でDeveloper ID署名・公証なし。Windowsコード署名も未整備。
  開発環境のない両OSでの初回導入・更新・修復・削除と、全機能共通化は未完了です。
- 現行GUI/旧scriptダウンローダーはGitHubのlatest通常Releaseを取得し、Pre-releaseを
  拒否します。候補をPre-releaseで公開する場合は、公開前にプレビュー取得経路を整える
  必要があります。候補名にbetaがあるだけではGitHubの公開区分は確定しません。

### ローカル確認結果

- CastorCore: 132件成功。Desktop: 57件成功。Mac app既存単体検査成功。
- Python speech: 8件成功。配布/model/privacy: 18件中5件platform skip、残り成功。
- Mac候補内の4モデルをCPU Core MLで読み込み成功。顔推定精度の証明ではありません。
- Mac候補の深い署名検証成功。ad-hoc署名であり配布者の認証・公証を意味しません。

公開可否の確認はこれらの記録と未確認事項を示してから行います。
