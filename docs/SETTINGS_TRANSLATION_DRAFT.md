# Castor 設定 翻訳カタログ案

この文書は、GPT-6 Lunaが作成した翻訳案を基に、GPT-6.1 Solで実装した macOS 設定画面と Windows 設定フローの表示文字列と安定キーを記録します。キーは UI 上の意味に固定し、文言の修正で変更しません。Mac は現行英語を基準に日英を整え、Windows は現行日本語を基準に整えました。

- 対象: `Castor/Castor/SettingsView.swift`、`CastorDesktop/Sources/CastorPet/ConversationFlow.swift`、`CastorDesktop/Sources/PetRuntime/DesktopPreferences.swift`。画面内で参照される選択肢ラベルも、実装済みの文字列を照合して含めています。
- `{...}` は実行時に値を差し込む箇所です。値の形式・順序を実装時に保ってください。
- `LM Studio`、`Ollama`、`Codex`、`Claude Code`、`LaMa`、`Arils`、`Qwen` などの製品名・モデル名、モデルID、voice名、URL、コマンド、設定値そのものは翻訳しません。数値や `BETA` の表示も値として維持します。
- UIにない設定・機能や完成を示唆する説明は追加していません。準備用コマンドや権限など、現行画面にある注意は残しています。

## macOS 設定画面

| 現行ソース文字列 | 安定キー案 | ja | en |
|---|---|---|---|
| `General` | `settings.tab.general` | 一般 | General |
| `Input` | `settings.tab.input` | 入力 | Input |
| `Voice` | `settings.tab.voice` | 音声 | Voice |
| `Brain` | `settings.tab.brain` | AI | Brain |
| `Appearance` | `settings.appearance.label` | 外観 | Appearance |
| `System` | `settings.appearance.system` | システム設定に合わせる | System |
| `Light` | `settings.appearance.light` | ライト | Light |
| `Dark` | `settings.appearance.dark` | ダーク | Dark |
| `Pet Evasion` | `settings.evasion.label` | ペットの退避 | Pet Evasion |
| `When another app covers the pet, it can move aside as your pointer approaches. Off by default while this behavior is in beta. Whatever this setting, hold Option over the pet to see through it and click what it covers.` | `settings.evasion.help` | 別のアプリに隠れたペットは、ポインタが近づくと場所を譲ります。ベータ機能のため、初期設定ではオフです。この設定にかかわらず、ペットの上で Option キーを押すと透過し、下にあるものをクリックできます。 | When another app covers the pet, it can move aside as your pointer approaches. This beta feature is off by default. Hold Option over the pet to see through it and click what it covers, regardless of this setting. |
| `LaMa Underpaint` | `settings.lama.label` | LaMa による画像補修 | LaMa Underpaint |
| `Check local service` | `settings.lama.check` | ローカルサービスを確認 | Check Local Service |
| `The local helper may not be installed or running.` | `settings.lama.missing` | ローカル補助ツールがインストールされていないか、起動していない可能性があります。 | The local helper may not be installed or running. |
| `If it is not installed, run this from the repository root:` | `settings.lama.install_help` | 未インストールの場合は、リポジトリのルートで次のコマンドを実行してください。 | If it is not installed, run this from the repository root: |
| `Then start the local service:` | `settings.lama.start_help` | 続けてローカルサービスを起動してください。 | Then start the local service: |
| `Uses the optional LaMa helper only while a new Arils avatar is built. It is off by default, sends images only to 127.0.0.1, and falls back to the standard repair if the helper is unavailable.` | `settings.lama.help` | 任意の LaMa 補助ツールを、新しい Arils アバターの作成中だけ使用します。初期設定ではオフです。画像の送信先は 127.0.0.1 のみで、補助ツールが使えない場合は標準の補修方法に切り替わります。 | Uses the optional LaMa helper only while a new Arils avatar is built. It is off by default, sends images only to 127.0.0.1, and falls back to the standard repair if the helper is unavailable. |
| `Ready` | `settings.service.ready` | 利用できます | Ready |
| `Loading model…` | `settings.service.loading_model` | モデルを読み込み中… | Loading model… |
| `Service online; model loads on first use` | `settings.service.model_on_demand` | サービスに接続しました。モデルは初回使用時に読み込まれます。 | Service is online; the model will load on first use. |
| `Anime Face Landmarks` | `settings.face_landmarks.label` | アニメ顔ランドマーク | Anime Face Landmarks |
| `The model files are not in this build. Face review uses the built-in estimator.` | `settings.face_landmarks.model_missing` | このビルドにはモデルファイルが含まれていないため、顔の確認には内蔵の推定器を使います。 | The model files are not included in this build. Face review uses the built-in estimator. |
| `Places the head, eye, and mouth markers in face review with an anime-trained landmark model that runs on this Mac. Nothing is sent anywhere; turn it off to use the built-in estimator.` | `settings.face_landmarks.help` | この Mac 上で動作するアニメ向けランドマークモデルを使い、顔の確認画面で頭・目・口の位置を推定します。データは外部へ送信されません。オフにすると内蔵の推定器を使います。 | Uses an anime-trained landmark model running on this Mac to place head, eye, and mouth markers during face review. Nothing is sent anywhere. Turn it off to use the built-in estimator. |
| `Manual rigging` | `settings.manual_rigging.label` | 手動リギング | Manual Rigging |
| `Advanced` | `settings.advanced.heading` | 詳細設定 | Advanced |
| `Shows the legacy rectangle rig editor in Rigging, for images Arils cannot rig yet. Pets can then be saved without an Arils rig.` | `settings.manual_rigging.help` | Arils でまだリギングできない画像向けに、「リギング」に従来の矩形リグ編集画面を表示します。Arils のリグを使わずにペットを保存できます。 | Shows the legacy rectangle rig editor in Rigging for images Arils cannot rig yet. You can then save pets without an Arils rig. |
| `Button-aware dodge` | `settings.button_dodge.label` | ボタンに合わせて退避 | Button-Aware Dodge |
| `Check local helper` | `settings.button_dodge.check` | ローカル補助ツールを確認 | Check Local Helper |
| `Ready` | `settings.helper.ready` | 利用できます | Ready |
| `Running; allow it in System Settings › Privacy & Security › Accessibility` | `settings.helper.accessibility_required` | 起動中です。「システム設定」›「プライバシーとセキュリティ」›「アクセシビリティ」で許可してください。 | Running. Allow it in System Settings › Privacy & Security › Accessibility. |
| `Not running` | `settings.helper.not_running` | 起動していません | Not running |
| `Set up and start the helper from the repository root:` | `settings.helper.setup_help` | リポジトリのルートで補助ツールをセットアップし、起動してください。 | Set up and start the helper from the repository root: |
| `When your pointer moves onto the pet over a button or other control of another app, the pet slides aside so you can click it, then returns. Knowing what is underneath needs a local helper with Accessibility permission, because the sandboxed app cannot look at other apps itself. The helper reports only the kind of control, never its text, and listens on 127.0.0.1 only.` | `settings.button_dodge.help` | 別のアプリのボタンなどに重なったペットへポインタを移動すると、ペットが一時的に場所を譲り、クリック後に戻ります。下にある項目を調べるには、アプリのサンドボックス外を参照できないため、アクセシビリティ権限を持つローカル補助ツールが必要です。補助ツールが取得するのはコントロールの種類だけで、表示文字は取得しません。接続は 127.0.0.1 内に限られます。 | When your pointer moves over a button or other control in another app, the pet moves aside so you can click it, then returns. Identifying the control underneath requires a local helper with Accessibility permission because the sandboxed app cannot inspect other apps. The helper reports the control type only, never its text, and listens on 127.0.0.1 only. |
| `Wider head movement` | `settings.wide_head.label` | 首振りを大きくする | Wider Head Movement |
| `Arils pets turn and tilt their head about twice as far toward what they look at, and the body follows. A single picture has nothing behind the head, so edges or a gap can show at the far end of a turn.` | `settings.wide_head.help` | Arils のペットが視線の先へ向ける首振りと傾きの範囲を約 2 倍にし、体も追従します。1 枚の画像には頭の後ろの絵がないため、大きく振り向いたときに画像の端や隙間が見えることがあります。 | Arils pets turn and tilt their heads about twice as far toward what they look at, with the body following. A single image has no artwork behind the head, so edges or gaps may show at the far end of a turn. |
| `Routing` | `settings.agent.routing` | 依頼の振り分け | Routing |
| `Choose each time` | `settings.agent.routing.manual` | 毎回選ぶ | Choose Each Time |
| `Let Castor decide` | `settings.agent.routing.automatic` | Castor に任せる | Let Castor Decide |
| `Brain for the next message` | `settings.agent.next_brain` | 次のメッセージの送信先 | Brain for the Next Message |
| `External agent` | `settings.agent.external_brain` | 外部エージェント | External Agent |
| `On-device` | `settings.agent.on_device` | 端末内 | On-Device |
| `Codex` | `settings.agent.codex` | Codex | Codex |
| `Claude Code` | `settings.agent.claude_code` | Claude Code | Claude Code |
| `Antigravity` | `settings.agent.antigravity` | Antigravity | Antigravity |
| `· Soon` | `settings.agent.coming_soon_suffix` | ・近日対応 | · Coming Soon |
| `Castor brain` | `settings.agent.section` | Castor の応答先 | Castor Brain |
| `Keep conversations local, or let an external agent act through Castor.` | `settings.agent.routing.manual_help` | 会話を端末内で行うか、外部エージェントに Castor 経由で操作を依頼できます。 | Keep conversations on-device, or let an external agent act through Castor. |
| `Everyday chat stays on-device. Requests involving files, apps, commands, or development are sent to the selected external agent.` | `settings.agent.routing.automatic_help` | 通常の会話は端末内で行います。ファイル・アプリ・コマンド・開発に関する依頼は、選択した外部エージェントへ送ります。 | Everyday chat stays on-device. Requests involving files, apps, commands, or development are sent to the selected external agent. |
| `Server URL` | `settings.codex.url` | サーバー URL | Server URL |
| `Start Codex with Castor` | `settings.codex.start` | Castor から Codex を起動 | Start Codex with Castor |
| `Connect Castor to Codex?` | `settings.codex.disclosure.title` | Castor を Codex に接続しますか？ | Connect Castor to Codex? |
| `Cancel` | `common.cancel` | キャンセル | Cancel |
| `I Understand and Start` | `settings.agent.disclosure.confirm` | 内容を理解して起動 | I Understand and Start |
| `Codex may send your messages, selected workspace context, and command or file-operation details to OpenAI services. This can use Codex plan or API tokens, and data handling follows your Codex and OpenAI settings. On-device mode does not use this Codex connection. Castor starts the local Codex app server on this Mac only; choose Codex in Castor to use it.` | `settings.codex.disclosure.body` | Codex は、メッセージ、選択したワークスペースの情報、コマンドやファイル操作の詳細を OpenAI のサービスへ送信する場合があります。Codex のプランまたは API トークンを使用することがあり、データの取り扱いは Codex と OpenAI の設定に従います。端末内モードではこの Codex 接続を使用しません。Castor はこの Mac 上でローカルの Codex app server だけを起動します。使用するには Castor で Codex を選んでください。 | Codex may send your messages, selected workspace context, and command or file-operation details to OpenAI services. This may use your Codex plan or API tokens; data handling follows your Codex and OpenAI settings. On-device mode does not use this connection. Castor starts the local Codex app server on this Mac only. Choose Codex in Castor to use it. |
| `Codex App Server` | `settings.codex.section` | Codex App Server | Codex App Server |
| `Requires the Codex CLI installed and signed in. Castor runs it in the background while Castor is open and stops it when you quit.` | `settings.codex.help` | Codex CLI のインストールとサインインが必要です。Castor の起動中はバックグラウンドで実行し、Castor を終了すると停止します。 | Requires the Codex CLI to be installed and signed in. Castor runs it in the background while Castor is open and stops it when you quit. |
| `Bridge URL` | `settings.claude.url` | Bridge URL | Bridge URL |
| `Start the Claude Code bridge with Castor` | `settings.claude.start` | Castor から Claude Code bridge を起動 | Start the Claude Code Bridge with Castor |
| `Connect Castor to Claude Code?` | `settings.claude.disclosure.title` | Castor を Claude Code に接続しますか？ | Connect Castor to Claude Code? |
| `Claude Code may send your messages and selected workspace context to Anthropic services and can use your Claude plan or API billing. The local bridge asks Castor before unresolved commands or file operations run. On-device mode does not use this connection. Castor starts the bridge on this Mac only; choose Claude Code in Castor to use it.` | `settings.claude.disclosure.body` | Claude Code は、メッセージと選択したワークスペースの情報を Anthropic のサービスへ送信する場合があり、Claude のプランまたは API の利用料金が発生することがあります。未解決のコマンドやファイル操作を実行する前に、ローカル bridge が Castor を通じて確認を求めます。端末内モードではこの接続を使用しません。Castor はこの Mac 上で bridge だけを起動します。使用するには Castor で Claude Code を選んでください。 | Claude Code may send your messages and selected workspace context to Anthropic services, and may use your Claude plan or incur API charges. The local bridge asks for your approval in Castor before running commands or file operations that need approval. On-device mode does not use this connection. Castor starts the bridge on this Mac only. Choose Claude Code in Castor to use it. |
| `Claude Code Bridge` | `settings.claude.section` | Claude Code Bridge | Claude Code Bridge |
| `Requires Claude Code installed and signed in. The bridge listens only on this Mac and does not store API credentials. It also needs Python 3, which comes with the Command Line Tools.` | `settings.claude.help` | Claude Code のインストールとサインインが必要です。bridge はこの Mac からの接続だけを受け付け、API 認証情報を保存しません。また、Command Line Tools に含まれる Python 3 が必要です。 | Requires Claude Code to be installed and signed in. The bridge accepts connections only from this Mac and does not store API credentials. It also needs Python 3, included with the Command Line Tools. |
| `Workspace folder` | `settings.agent.workspace` | ワークスペースフォルダ | Workspace Folder |
| `Choose...` | `settings.agent.workspace.choose` | 選択… | Choose… |
| `External agent workspace` | `settings.agent.workspace.section` | 外部エージェントの作業フォルダ | External Agent Workspace |
| `Codex and Claude Code receive this folder as their working directory. Choose only a workspace you intend to share with the selected service.` | `settings.agent.workspace.help` | Codex と Claude Code は、このフォルダを作業ディレクトリとして受け取ります。選択したサービスと共有してよいフォルダを選んでください。 | Codex and Claude Code receive this folder as their working directory. Choose only a workspace you intend to share with the selected service. |
| `Status` | `settings.local_ai.status` | 状態 | Status |
| `Refresh` | `settings.local_ai.refresh` | 更新 | Refresh |
| `Connect` | `settings.local_ai.connect` | 接続 | Connect |
| `Start LM Studio or Ollama and install a model to continue.` | `settings.local_ai.empty` | 続けるには LM Studio または Ollama を起動し、モデルをインストールしてください。 | Start LM Studio or Ollama and install a model to continue. |
| `Model` | `settings.local_ai.model` | モデル | Model |
| ` • Size unknown` | `settings.local_ai.size_unknown_suffix` | ・サイズ不明 | • Size Unknown |
| ` — For conversation; may be inaccurate` | `settings.local_ai.small_model_suffix` | — 会話向けです。回答が不正確な場合があります | — For Conversation; May Be Inaccurate |
| `Below about 7B parameters: suited to casual conversation; answers may be inaccurate. Size is only a rough guide.` | `settings.local_ai.small_model_notice` | 約 7B 未満のモデルです。気軽な会話向けですが、回答が不正確な場合があります。パラメータ数は目安です。 | Below about 7B parameters. Suited to casual conversation, but answers may be inaccurate. Parameter count is only a rough guide. |
| `Acceleration` | `settings.local_ai.acceleration` | 高速化 | Acceleration |
| `Managed by LM Studio` | `settings.local_ai.acceleration_managed` | LM Studio が管理 | Managed by LM Studio |
| `Say something to Castor` | `settings.local_ai.prompt` | Castor に話しかける | Say something to Castor |
| `Send to local AI` | `settings.local_ai.send` | 端末内 AI に送信 | Send to Local AI |
| `Local AI` | `settings.local_ai.section` | 端末内 AI | Local AI |
| `LM Studio at {ollama.lmStudioEndpoint.absoluteString} • Ollama at {ollama.ollamaEndpoint.absoluteString}\nLM Studio is preferred when both have conversational models. DFlash, DSpark, and MTP follow the model's load settings in LM Studio when supported.` | `settings.local_ai.help` | LM Studio: {ollama.lmStudioEndpoint.absoluteString} • Ollama: {ollama.ollamaEndpoint.absoluteString}\n両方に会話用モデルがある場合は LM Studio を優先します。対応モデルでは、DFlash、DSpark、MTP の設定は LM Studio でのモデル読み込み設定に従います。 | LM Studio: {ollama.lmStudioEndpoint.absoluteString} • Ollama: {ollama.ollamaEndpoint.absoluteString}\nLM Studio is preferred when both have conversational models. DFlash, DSpark, and MTP follow the model's load settings in LM Studio when supported. |
| `Not connected` | `settings.local_ai.disconnected` | 未接続 | Not Connected |
| `Connecting` | `settings.local_ai.connecting` | 接続中 | Connecting |
| `Connected — {provider.label}` / `Connected` | `settings.local_ai.connected` | 接続済み — {provider.label} / 接続済み | Connected — {provider.label} / Connected |
| `Choose the workspace Castor may give to external agents` | `settings.agent.workspace.dialog_title` | Castor が外部エージェントに渡してよいワークスペースを選択 | Choose the Workspace Castor May Share with External Agents |
| `Camera input` | `settings.input.camera` | カメラ入力 | Camera Input |
| `Permission: {cameraPermission.label}` | `settings.input.camera_permission` | 権限: {cameraPermission.label} | Permission: {cameraPermission.label} |
| `Ambient audio reactions` | `settings.input.ambient_audio` | 周囲の音への反応 | Ambient Audio Reactions |
| `Microphone` | `settings.input.microphone` | マイク | Microphone |
| `Level` | `settings.input.level` | 音量 | Level |
| `Microphone permission: {microphonePermission.label}\nThis toggle controls always-on audio-level reactions. Voice chat uses the selected microphone only while the mic button is active.` | `settings.input.microphone_help` | マイクの権限: {microphonePermission.label}\nこの設定は音量に応じた常時反応を切り替えます。音声チャットでは、マイクボタンを押している間だけ選択中のマイクを使います。 | Microphone permission: {microphonePermission.label}\nThis setting controls always-on reactions to audio levels. Voice chat uses the selected microphone only while the mic button is active. |
| `Neural voice` | `settings.voice.engine` | 音声エンジン | Neural Voice |
| `Preparing Qwen 0.6B...` | `settings.voice.preparing` | Qwen 0.6B を準備中… | Preparing Qwen 0.6B… |
| `{neuralSpeechSettings.voiceEngine.detail}` | `settings.voice.engine_help` | 選択した音声エンジンの説明（実装済みの detail 文字列を翻訳対象として登録） | Description for the selected voice engine (localize the existing detail string). |
| `Restart` | `settings.agent.restart` | 再起動 | Restart |
| `Copy Terminal command` | `settings.agent.copy_command` | ターミナル用コマンドをコピー | Copy Terminal Command |

## Windows 設定・会話フロー

| 現行ソース文字列 | 安定キー案 | ja | en |
|---|---|---|---|
| `Castor - 設定（保存して閉じるまで適用しません）` | `desktop.settings.title` | Castor - 設定（保存して閉じるまで変更は適用されません） | Castor - Settings (Changes apply when you save and close) |
| `会話サービス: {provider}` | `desktop.settings.provider` | 会話サービス: {provider} | Chat Service: {provider} |
| `ローカル接続先: {endpoint}` | `desktop.settings.endpoint` | 接続先: {endpoint} | Service URL: {endpoint} |
| `モデル: {model}` | `desktop.settings.model` | モデル: {model} | Model: {model} |
| `キャラクターの性格` | `desktop.settings.personality` | キャラクターの性格 | Character Personality |
| `自動視点: {オン/オフ}` | `desktop.settings.automatic_turn` | 自動で視線に合わせる: {オン/オフ} | Follow Gaze Automatically: {On/Off} |
| `広い首振り: {オン/オフ}` | `desktop.settings.wide_head` | 首振りを大きくする: {オン/オフ} | Wider Head Movement: {On/Off} |
| `ペットの不透明度: {percentage}` | `desktop.settings.opacity` | ペットの不透明度: {percentage} | Pet Opacity: {percentage} |
| `ペットの大きさ: {percentage}` | `desktop.settings.scale` | ペットの大きさ: {percentage} | Pet Size: {percentage} |
| `標準読み上げ: {オン/オフ}` | `desktop.settings.system_tts` | システム音声で読み上げ: {オン/オフ} | System Text-to-Speech: {On/Off} |
| `標準音声を選ぶ` | `desktop.settings.choose_voice` | システム音声を選ぶ | Choose System Voice |
| `Brain: {selectedBrain.rawValue}` | `desktop.settings.brain` | 応答先: {selectedBrain.rawValue} | Response Destination: {selectedBrain.rawValue} |
| `自動ルーティング: {オン/オフ}` | `desktop.settings.automatic_routing` | 依頼を自動で振り分ける: {オン/オフ} | Route Requests Automatically: {On/Off} |
| `自動時の外部Brain: {externalBrain.rawValue}` | `desktop.settings.automatic_external_brain` | 自動振り分け時の外部エージェント: {externalBrain.rawValue} | External Agent for Automatic Routing: {externalBrain.rawValue} |
| `Codex App Server接続先` | `desktop.settings.codex_endpoint` | Codex App Server の接続先 | Codex App Server URL |
| `Claude Code Bridge接続先` | `desktop.settings.claude_endpoint` | Claude Code Bridge の接続先 | Claude Code Bridge URL |
| `操作対象フォルダ` | `desktop.settings.workspace` | 作業フォルダ | Workspace Folder |
| `退避・帰巣: {オン/オフ}` | `desktop.settings.evasion` | 退避と元の位置への復帰: {オン/オフ} | Move Aside and Return: {On/Off} |
| `退避スタイル: {style.label}` | `desktop.settings.evasion_style` | 退避スタイル: {style.label} | Evasion Style: {style.label} |
| `保存して閉じる` | `desktop.settings.save_close` | 保存して閉じる | Save and Close |
| `変更を破棄して閉じる` | `desktop.settings.discard_close` | 変更を破棄して閉じる | Discard Changes and Close |
| `会話サービス` | `desktop.settings.provider.title` | 会話サービス | Chat Service |
| `LM Studio` / `Ollama` | `desktop.settings.provider.lmstudio` / `desktop.settings.provider.ollama` | LM Studio / Ollama | LM Studio / Ollama |
| `ローカル接続先（http(s)://127.0.0.1 / localhost / [::1]）` | `desktop.settings.endpoint.title` | 接続先（http(s)://127.0.0.1 / localhost / [::1]） | Service URL (http(s)://127.0.0.1 / localhost / [::1]) |
| `ローカルサービスの会話用モデルを取得しています。` | `desktop.settings.models.loading` | ローカルサービスから会話用モデルを取得しています。 | Loading chat models from the local service. |
| `会話用モデルを選択（小さなモデルも選べます）` | `desktop.settings.models.choose` | 会話用モデルを選択（小さなモデルも選べます） | Choose a Chat Model (Smaller Models Are Also Available) |
| `{model.name} ({parameterSizeLabel}) — 7B未満の目安` | `desktop.settings.models.item` | {model.name} ({parameterSizeLabel}) — 約 7B 未満の目安 | {model.name} ({parameterSizeLabel}) — Under About 7B |
| `キャラクターの会話上の性格` | `desktop.settings.personality.title` | 会話でのキャラクターの性格 | Character's Conversational Personality |
| `ペットの不透明度` | `desktop.settings.opacity.title` | ペットの不透明度 | Pet Opacity |
| `ペットの大きさ` | `desktop.settings.scale.title` | ペットの大きさ | Pet Size |
| `Windows標準音声` | `desktop.settings.voice.title` | Windows のシステム音声 | Windows System Voice |
| `システム既定` | `desktop.settings.voice.system_default` | システム既定 | System Default |
| `Brain（外部接続は送信時に行います）` | `desktop.settings.brain.title` | 応答先（外部サービスへの接続は依頼の送信時に行います） | Response Destination (External Services Connect When You Send a Request) |
| `ローカル会話` | `desktop.settings.brain.local` | 端末内で会話 | On-Device Chat |
| `Codex` / `Claude Code` | `desktop.settings.brain.codex` / `desktop.settings.brain.claude_code` | Codex / Claude Code | Codex / Claude Code |
| `操作依頼の転送先` | `desktop.settings.external_brain.title` | 操作依頼の送信先 | Agent for Action Requests |
| `Codex App Server（ローカルWebSocketのみ）` | `desktop.settings.codex.url_title` | Codex App Server（この PC 内の WebSocket 接続のみ） | Codex App Server (Local WebSocket Only) |
| `Claude Code Bridge（ローカルHTTPのみ）` | `desktop.settings.claude.url_title` | Claude Code Bridge（この PC 内の HTTP 接続のみ） | Claude Code Bridge (Local HTTP Only) |
| `操作対象フォルダのフルパス` | `desktop.settings.workspace.full_path` | 作業フォルダのパス | Workspace Path |
| `退避スタイル` | `desktop.settings.evasion_style.title` | 退避スタイル | Evasion Style |
| `Cute` / `Calm` / `Cool` / `Proud` / `Robot` | `desktop.settings.evasion_style.cute` / `.calm` / `.cool` / `.proud` / `.robot` | かわいい / おだやか / クール / 自信たっぷり / ロボット風 | Cute / Calm / Cool / Confident / Robot |
| `Castor - 会話/操作依頼（転送先はBrain設定で選択）` | `desktop.chat.prompt.title` | Castor - 会話 / 操作依頼（送信先は設定で選択） | Castor - Chat or Request an Action (Choose the Destination in Settings) |
| `ローカルモデルが応答を生成しています。` | `desktop.chat.generating` | ローカルモデルが応答を生成しています。 | The local model is generating a response. |
| `Castor - 応答（選択してコピーできます）` | `desktop.chat.reply.title` | Castor - 応答（選択してコピーできます） | Castor - Response (Select Text to Copy) |
| `表示設定・性格の長さを確認してください。既存の設定は保持しています。` | `desktop.settings.invalid_preferences` | 表示設定または性格の文字数を確認してください。既存の設定は保持されています。 | Check the display settings and personality length. Your existing settings have been kept. |

## 実装時の確認点

1. 共通カタログ `CastorCore/Settings/SettingsLocalization.swift` を両OSの設定へ接続済みです。初回はOSの優先言語が日本語なら日本語、それ以外はEnglishを使い、言語選択を強制しません。MacはGeneral/一般、Windowsは設定の「表示言語」で変更できます。Macは `Castor.SettingsDisplayLanguage`、Windowsは既存Preferences JSONへの `displayLanguage` 追加で保存します。rootのSwiftUI localeも同じ値を使います。表示言語はモデルID・voice ID・性格・音声認識言語・既存保存キーを変更しません。
2. Voice engineの説明、権限状態、AgentLauncherの固定状態と導入案内、LaMaの固定状態を定義元と照合し、表示側のカタログへ追加しました。動的エラー本文は原文を保持し、停止・利用不可などの固定接頭辞を翻訳します。
3. Windows の `evasionStyle.label` と brain raw value は現在の表示値をそのまま差し込む箇所です。永続化値・enum raw value は翻訳せず、表示ラベルのみを別途ローカライズしてください。
4. Windows のローカル接続先・Agent 接続先は編集可能な URL です。ラベルや説明のみを翻訳し、入力値は変換しません。

## 追加した導線と検査

- Macのマイクが拒否状態ならInput/入力にシステム設定を開くボタンと再有効化の案内を表示します。文字会話は利用できます。
- Windowsは音量反応用の `microphoneEnabled` と初回確認用の `microphoneSetupCompleted` をfalse既定で追加しました。設定変更は保存して閉じるまで既存どおり確定しません。
- カタログにない動的なサービスエラー・ユーザー本文は原文を保持します。voiceの製品名や端末が列挙する音声名は翻訳しません。
- 翻訳両言語の存在、未知キーfallback、差し込み値の非再解釈、外部接続説明、旧設定互換性、未知言語での既存ファイル保持を回帰検査します。ビルド/純粋ロジック検査と実機GUI確認は別です。

## 残りのmacOS UIへの適用

`APP_TRANSLATION_DRAFT.json` のLuna案を基に、共通 `CastorAppStrings` とMacの画像リギング・顔確認・被写体選択・Quality確認・音声選択・フローティング会話・回答の展開・GIF共有へ実装しました。日本語だけだった音声の説明、Qualityの注意、GIFの手動添付案内にも英語を追加しました。独立したペット/GIFウインドウも同じ言語保存値を監視します。

静的表示とCastorが生成する状態の接頭辞/テンプレートを翻訳し、ユーザーの会話、AIの提案本文、承認カードの実コマンド/詳細、ファイル名、voice/model IDは原文を保ちます。動的テンプレートは具体的な文言を優先し、差し込んだ値を再解釈しません。座標は従来の小数2桁を保ちます。保存形式・リグの値・実際の操作は変更していません。
