import CDesktopUI
import Foundation
import PetRuntime
import CastorCore

/// The installer uses the OS language independently of the installed app's saved preferences.
/// This value contains UI text only; install paths, component IDs and stored records stay intact.
struct SetupLocalization: Sendable {
    let language: SettingsDisplayLanguage = .systemDefault
    var isJapanese: Bool { language == .japanese }
    func text(_ japanese: String, _ english: String) -> String { isJapanese ? japanese : english }
    var title: String { text("Castor - 導入・更新・修復", "Castor - Install, Update and Repair") }
    var intro: String { text("OS/CPUに合うアプリを取得します。既存のペット・設定は保持します。", "Download the app for your OS and CPU. Existing pets and settings are kept.") }
    var cancel: String { text("キャンセル", "Cancel") }
    var close: String { text("閉じる", "Close") }
    var cleanupButton: String { text("古い版を整理", "Clean up older versions") }
    var cleanupPolicy: String {
        text("旧版整理では、現在版と1つ前、使用中・変更された版、指紋のない版・不明フォルダを保持します。確認できたそれ以前の版だけをOSのごみ箱へ送ります。モデルキャッシュ・ペット・設定は保持します。",
             "Cleanup keeps the current and previous versions, in-use or modified versions, versions without fingerprints, and unknown folders. Only verified older versions are sent to the OS Trash or Recycle Bin. Model cache, pets, and settings are kept.")
    }
    var cleanupFinished: String {
        text("古い版の整理が完了しました。", "Cleanup of older versions finished.") + "\n\n" + cleanupPolicy
    }
    func cleanupFailed(_ error: Error) -> String {
        text("古い版の整理を完了できませんでした。現在の導入は保持しています。", "Cleanup of older versions could not be completed. The current installation was kept.")
            + "\n\n" + errorMessage(error)
    }
    var securityNotice: String {
        text("GitHub Releasesから取得します。SHA-256は同じ配布元の一覧との照合であり、真正性の保証ではありません。OSの安全確認を解除しません。",
             "Downloads come from GitHub Releases. SHA-256 checks against the same distributor's manifest do not guarantee authenticity. OS security checks remain enabled.")
    }
    var macFirstLaunch: String {
        text("Macの初回起動: 未署名または開発署名のアプリはGatekeeperに止められる場合があります。まずアプリを開き、警告を閉じてから「システム設定」>「プライバシーとセキュリティ」>「このまま開く」を選び、認証して起動を確認してください。必要な場合は、この導入アプリ（CastorSetup）・Castor本体・Neural TTS helperのそれぞれで行います。Developer ID署名・公証と実機動作の確認は未完了です。",
             "First launch on Mac: Gatekeeper may block unsigned or development-signed apps. Try opening the app, dismiss the warning, then go to System Settings > Privacy & Security > Open Anyway, authenticate, and confirm opening it. If needed, repeat this for this installer (CastorSetup), Castor, and the Neural TTS helper individually. Developer ID signing, notarization, and real-device checks are not complete.")
    }
    func removalTitle(helper: Bool) -> String {
        helper ? text("Neural TTS helperを削除しますか？", "Remove the Neural TTS helper?")
            : text("Castor本体を削除しますか？", "Remove the Castor app?")
    }
    func removalDetail(helper: Bool) -> String {
        helper ? text("削除するのは導入済みのNeural TTS helperです。Castor本体、モデルキャッシュ、ペット・会話設定は保持します。",
                      "Remove the installed Neural TTS helper. The Castor app, model cache, pets, and conversation settings are kept.")
            : text("Castor本体を削除します。ペット・会話設定、モデルキャッシュと別途導入したNeural TTS helperは保持します。",
                   "Remove the Castor app. Pets, conversation settings, model cache, and the separately installed Neural TTS helper are kept.")
    }
    func removed(helper: Bool) -> String {
        helper ? text("Neural TTS helperを削除しました。Castor本体、モデルキャッシュ、ペット・設定は保持しています。",
                      "The Neural TTS helper was removed. The Castor app, model cache, pets, and settings were kept.")
            : text("Castor本体を削除しました。ペット・設定、モデルキャッシュとNeural TTS helperは保持しています。",
                   "The Castor app was removed. Pets, settings, model cache, and the Neural TTS helper were kept.")
    }
    func notInstalled(helper: Bool) -> String {
        helper ? text("Neural TTS helperはまだ導入されていません。「取得・更新」で導入してください。", "The Neural TTS helper is not installed. Choose Download / Update to install it.")
            : text("Castorはまだ導入されていません。「取得・更新」で導入してください。", "Castor is not installed. Choose Download / Update to install it.")
    }
    func errorMessage(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return text("キャンセルしました。既存アプリとデータは保持しています。", "Cancelled. Existing apps and data were kept.")
        }
        if let error = error as? DesktopInstaller.InstallError {
            switch error {
            case .noRelease:
                return text("公開された配布Releaseがまだありません。ソース公開だけではアプリを取得できません。", "No distribution release has been published yet. Publishing source code alone does not provide a downloadable app.")
            case .invalidManifest:
                return text("配布情報が不正、またはこのOS/CPU向け本体・追加helperがありません。", "The distribution information is invalid, or the app or helper is not available for this OS and CPU.")
            case .downloadFailed(let status):
                return text("取得に失敗しました（HTTP \(status)）。既存アプリとデータは保持しています。", "Download failed (HTTP \(status)). Existing apps and data were kept.")
            case .integrity:
                return text("容量またはSHA-256が一致しません。既存アプリを保持して取得を中止しました。", "The size or SHA-256 does not match. The download was stopped and the existing app was kept.")
            case .existing:
                return text("同じ版が既にあります。起動または修復を選んでください。", "This version is already installed. Choose Launch or Repair.")
            case .missingApp:
                return text("展開したアプリ本体または必要なランタイムがありません。", "The extracted app or a required runtime is missing.")
            case .busy:
                return text("別の導入・削除が処理中です。終了後にもう一度実行してください。", "Another installation or removal is in progress. Wait for it to finish, then try again.")
            }
        }
        if let error = error as? NativeInstall.AdapterError {
            switch error {
            case .unsupported:
                return text("このOS/CPUにはまだ対応する配布アプリがありません。", "No distribution app is available for this OS and CPU yet.")
            case .unpack:
                return text("ZIPの展開またはアプリの導入・起動操作に失敗しました。ペット・設定は保持しています。", "The ZIP could not be extracted, or a native install or launch step failed. Pets and settings were kept.")
            case .stamp:
                return text("OSのネット由来の印を設定できませんでした。導入を中止しました。", "The OS marker for a downloaded file could not be set. Installation was stopped.")
            }
        }
        if error is PackageZIP.ZIPError {
            return text("配布ZIPの形式または内容が不正です。既存アプリは変更していません。", "The distribution ZIP has an invalid format or contents. The existing app was not changed.")
        }
        if isJapanese { return error.localizedDescription }
        // Unknown OS errors can use the OS's Japanese locale. Keep diagnostic identity without
        // inserting that localized message into the English installer.
        let diagnostic = error as NSError
        return "The operation could not be completed. Pets, settings, and model cache are kept. Diagnostic: \(diagnostic.domain) (\(diagnostic.code))."
    }
}

#if os(Windows)
import Dispatch
private final class SetupWork: @unchecked Sendable {
    let lock=NSLock();var result: Result<DesktopInstalledApp,Error>?
    var done: Bool { lock.lock();defer {lock.unlock()};return result != nil }
    func complete(_ value: Result<DesktopInstalledApp,Error>){lock.lock();result=value;lock.unlock()}
    func value() throws -> DesktopInstalledApp {lock.lock();defer{lock.unlock()};return try result!.get()}
}
private func setupUI() {
    let strings = SetupLocalization()
    func show(_ message: String, buttons: String? = nil) -> Int32 {
        message.withCString { title in (buttons ?? strings.close).withCString { castor_choose_option(title, $0) } }
    }
    do {
        let platform=try NativeInstall.platform
        while true {
            let options=strings.text("取得・更新\n導入済みアプリを起動\n修復（旧版を保持）\nCastor本体を削除（ペット・設定は保持）\nNeural TTS helperを取得・更新（任意）\nNeural TTS helperを起動\nNeural TTS helperを修復\nNeural TTS helperを削除（モデルキャッシュ保持）\nCastorの古い版を整理\nNeural TTS helperの古い版を整理\n終了",
                "Download / Update\nLaunch installed app\nRepair (keep previous version)\nRemove Castor (keep pets/settings)\nDownload / Update Neural TTS helper (optional)\nLaunch Neural TTS helper\nRepair Neural TTS helper\nRemove Neural TTS helper (keep model cache)\nClean up older Castor versions\nClean up older Neural TTS helper versions\nExit")
            let choice=strings.title.withCString { title in options.withCString {castor_choose_option(title,$0)} }
            if choice<=0 || choice==11 {return}
            // Existing app/helper actions keep their indices; the app cleanup item is not a helper.
            let component:DesktopHelperComponent?=[5,6,7,8,10].contains(choice) ? .neuralTTS:nil
            if choice==9 || choice==10 {
                do { try NativeInstall.pruneOldVersions(component:component); _ = show(strings.cleanupFinished) }
                catch { _ = show(strings.cleanupFailed(error)) }
                continue
            }
            let root=try NativeInstall.installationRoot(component:component)
            if choice==2 || choice==6 {
                if let app=try DesktopInstaller.selected(root:root){try NativeInstall.launch(app)}
                else { _ = show(strings.notInstalled(helper:component != nil)) }
                continue
            }
            if choice==4 || choice==8 {
                let confirm=show(strings.removalTitle(helper:component != nil)+"\n\n"+strings.removalDetail(helper:component != nil),
                    buttons:strings.text("削除する\nキャンセル", "Remove\nCancel"))
                if confirm==1 {
                    let old=try DesktopInstaller.selected(root:root)
                    try DesktopInstaller.uninstall(root:root)
                    if let old {NativeInstall.removeLaunchEntry(old)}
                    _ = show(old == nil ? strings.notInstalled(helper:component != nil) : strings.removed(helper:component != nil))
                }
                continue
            }
            let repair=choice==3 || choice==7,state=SetupWork()
            let job=Task.detached {
                do {
                    let (release,manifest)=try await DesktopInstaller.latest()
                    let app=try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:platform,
                        repair:repair,component:component,extract:{try await NativeInstall.extract($0,$1)},stamp:{try NativeInstall.stamp($0,component:component)})
                    state.complete(.success(app))
                } catch {state.complete(.failure(error))}
            }
            let progress=strings.text("対応する\(component == nil ? "アプリ" : "Neural TTS helper")を取得・検証・導入しています。SHA-256は配布者の真正性を保証しません。OSの安全確認を解除しません。",
                "Downloading, verifying, and installing the \(component == nil ? "app" : "Neural TTS helper") for this system. SHA-256 does not guarantee distributor authenticity. OS security checks remain enabled.")
            let status=progress.withCString {
                castor_wait_work($0,{context in Unmanaged<SetupWork>.fromOpaque(context!).takeUnretainedValue().done ? 1 : 0},Unmanaged.passUnretained(state).toOpaque())
            }
            if status<=0 {job.cancel();continue}
            do {
                let app=try state.value()
                do {
                    try NativeInstall.createLaunchEntry(app)
                    // Cleanup is best effort and cannot turn a completed installation into a failure.
                    try? NativeInstall.pruneOldVersions(component:component)
                } catch {
                    _ = show(strings.text("ショートカットを作れませんでした。既存の同名項目は保持しています。この導入アプリの起動ボタンから\(component == nil ? "Castor" : "Neural TTS helper")を開けます。",
                        "A shortcut could not be created. An existing item with the same name was kept. Use this installer's Launch button to open \(component == nil ? "Castor" : "the Neural TTS helper")."), buttons:strings.text("続ける", "Continue"))
                }
                let message=component == nil
                    ? strings.text("Castor \(app.version)を導入しました。初回にはSmartScreenの確認が出る場合があります。", "Castor \(app.version) was installed. SmartScreen may show a warning on first launch.")
                    : strings.text("Neural TTS helper \(app.version)を導入しました。モデルはhelper画面で任意に取得します。初回にはSmartScreenの確認が出る場合があります。", "Neural TTS helper \(app.version) was installed. Models can optionally be downloaded from the helper UI. SmartScreen may show a warning on first launch.")
                let launch=show(message+"\n\n"+strings.cleanupPolicy, buttons:strings.text("\(component == nil ? "Castor" : "Neural TTS helper")を起動\n後で起動",
                    "Launch \(component == nil ? "Castor" : "Neural TTS helper")\nLaunch Later"))
                if launch==1 {try NativeInstall.launch(app)}
            } catch {
                _ = show(strings.errorMessage(error), buttons:strings.text("閉じる（ペット・設定・モデルキャッシュは保持）", "Close (pets, settings, and model cache are kept)"))
            }
        }
    } catch {_ = show(strings.errorMessage(error))}
}
@main struct CastorWindowsSetup {
    static func main() {
        // Developer-only CI check; ordinary use always opens the GUI.
        let args=Array(CommandLine.arguments.dropFirst())
        if args.count==3,args[0]=="--check-extract" {
            Task.detached {
                do {
                    let archive=URL(fileURLWithPath:args[1]),destination=URL(fileURLWithPath:args[2])
                    try PackageZIP.validate(Data(contentsOf:archive),platform:"windows_x86_64")
                    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false)
                    try await NativeInstall.extract(archive,destination)
                    exit(0)
                } catch {fputs("Native extraction failed: \(error.localizedDescription)\n",stderr);exit(1)}
            }
            dispatchMain()
        }
        castor_set_ui_language(SettingsDisplayLanguage.systemDefault == .japanese ? 1:0)
        // The wizard window; the native dialogs remain for systems without WebView2.
        DispatchQueue.global(qos:.userInteractive).async {if !SetupWindow.run() {setupUI()};exit(0)}
        dispatchMain()
    }
}
#elseif os(macOS)
import AppKit
import SwiftUI
@MainActor final class SetupModel: ObservableObject {
    let strings = SetupLocalization()
    @Published var status=SetupLocalization().intro
    @Published var busy=false
    private var job: Task<Void,Never>?
    func install(repair: Bool=false,component:DesktopHelperComponent?=nil){
        guard !busy else{return};busy=true
        status=strings.text("\(component == nil ? "Castor" : "Neural TTS helper")を取得・検証・導入中...", "Downloading, verifying, and installing \(component == nil ? "Castor" : "the Neural TTS helper")...")
        job=Task {
            do {
                let (release,manifest)=try await DesktopInstaller.latest()
                let app=try await DesktopInstaller.install(root:NativeInstall.installationRoot(component:component),release:release,manifest:manifest,
                    platform:NativeInstall.platform,repair:repair,component:component,extract:{try await NativeInstall.extract($0,$1)},stamp:{try NativeInstall.stamp($0,component:component)})
                if let component {
                    do {
                        try NativeInstall.createLaunchEntry(app)
                        try? NativeInstall.pruneOldVersions(component:component)
                        status=strings.text("\(component.stem) helperを導入しました。Applicationsから起動できます。モデル取得はhelper画面で任意に行います。", "The \(component.stem) helper was installed. Launch it from Applications. Models can optionally be downloaded from the helper UI.")+"\n\n"+strings.cleanupPolicy
                    } catch {status=strings.text("Neural TTS helperは導入済みです。同名の既存アプリを保持したため入口を作れませんでした。起動ボタンで開けます。", "The Neural TTS helper was installed. A launch entry could not be created because an existing app with the same name was kept. Use the Launch button to open it.")}
                }
                else {do {try NativeInstall.createLaunchEntry(app);try? NativeInstall.pruneOldVersions(component:nil);status=strings.text("Castor \(app.version)を導入しました。ApplicationsのCastor.appから直接起動できます。", "Castor \(app.version) was installed. Open Castor.app directly from Applications.")+"\n\n"+strings.cleanupPolicy}
                catch {status=strings.text("Castor \(app.version)は導入済みです。同名の既存アプリを保持したため入口を作れませんでした。起動ボタンで開けます。", "Castor \(app.version) was installed. A launch entry could not be created because an existing app with the same name was kept. Use the Launch button to open it.")}}
            } catch {status=strings.errorMessage(error)}
            busy=false;job=nil
        }
    }
    func cancel(){job?.cancel()}
    func launch(component:DesktopHelperComponent?=nil){
        do{
            if let app=try DesktopInstaller.selected(root:NativeInstall.installationRoot(component:component)){try NativeInstall.launch(app)}
            else {status=strings.notInstalled(helper:component != nil)}
        }catch{status=strings.errorMessage(error)}
    }
    func cleanOlderVersions(component:DesktopHelperComponent?=nil) {
        guard !busy else { return }
        do { try NativeInstall.pruneOldVersions(component:component); status=strings.cleanupFinished }
        catch { status=strings.cleanupFailed(error) }
    }
    func remove(component:DesktopHelperComponent?=nil){
        let alert=NSAlert();alert.messageText=strings.removalTitle(helper:component != nil);alert.informativeText=strings.removalDetail(helper:component != nil)
        alert.addButton(withTitle:strings.text("削除", "Remove"));alert.addButton(withTitle:strings.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            do{
                let root=try NativeInstall.installationRoot(component:component)
                let old=try DesktopInstaller.selected(root:root)
                try DesktopInstaller.uninstall(root:root)
                if let old{NativeInstall.removeLaunchEntry(old)}
                status=old == nil ? strings.notInstalled(helper:component != nil) : strings.removed(helper:component != nil)
            }catch{status=strings.errorMessage(error)}
        }
    }
}
@main struct CastorSetupApp: App {
    @StateObject private var model=SetupModel()
    var body: some Scene {WindowGroup(model.strings.title) {
        VStack(alignment:.leading,spacing:16){
            Text("Castor").font(.largeTitle.bold());Text(model.status).textSelection(.enabled)
            Text(model.strings.securityNotice).font(.caption).foregroundStyle(.secondary)
            Text(model.strings.macFirstLaunch).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.busy {ProgressView();Button(model.strings.cancel){model.cancel()}}
            else {HStack{Button(model.strings.text("取得・更新", "Download / Update")){model.install()};Button(model.strings.text("起動", "Launch")){model.launch()};Button(model.strings.text("修復", "Repair")){model.install(repair:true)};Button(model.strings.text("アプリを削除", "Remove App")){model.remove()}}
                Button(model.strings.cleanupButton){model.cleanOlderVersions()}
                Divider()
                Text(model.strings.text("任意のNeural TTS helper。モデルはhelper画面で別途取得します。Pythonの手動導入は不要です。必要な場合だけ取得してください。", "Optional Neural TTS helper. Download models separately from the helper UI. No manual Python installation is required. Distribution candidates are still being validated."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack{Button(model.strings.text("Neural TTSを取得・更新", "Download / Update Neural TTS")){model.install(component:.neuralTTS)};Button(model.strings.text("起動", "Launch")){model.launch(component:.neuralTTS)};Button(model.strings.text("修復", "Repair")){model.install(repair:true,component:.neuralTTS)};Button(model.strings.text("削除", "Remove")){model.remove(component:.neuralTTS)}}
                Button(model.strings.cleanupButton){model.cleanOlderVersions(component:.neuralTTS)}
            }
        }.padding(24).frame(width:570).environment(\.locale,Locale(identifier:model.strings.language.rawValue))
            .onAppear{NSApplication.shared.setActivationPolicy(.regular);NSApplication.shared.activate(ignoringOtherApps:true)}
    }.windowResizability(.contentSize)}
}
#else
@main struct UnsupportedSetup { static func main() { print(SetupLocalization().text("CastorSetupはMacとWindowsに対応しています。", "CastorSetup supports Mac and Windows.")) } }
#endif
