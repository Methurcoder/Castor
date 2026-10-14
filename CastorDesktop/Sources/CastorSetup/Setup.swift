import CDesktopUI
import Foundation
import PetRuntime
import CastorCore

#if os(Windows)
import Dispatch
private final class SetupWork: @unchecked Sendable {
    let lock=NSLock();var result: Result<DesktopInstalledApp,Error>?
    var done: Bool { lock.lock();defer {lock.unlock()};return result != nil }
    func complete(_ value: Result<DesktopInstalledApp,Error>){lock.lock();result=value;lock.unlock()}
    func value() throws -> DesktopInstalledApp {lock.lock();defer{lock.unlock()};return try result!.get()}
}
private func setupUI() {
    do {
        let root=try NativeInstall.root,platform=try NativeInstall.platform
        while true {
            let options="取得・更新\n導入済みアプリを起動\n修復（旧版を保持）\nアプリを削除（ペット・設定は保持）\n終了"
            let choice="Castor - 導入・更新・修復".withCString { title in options.withCString {castor_choose_option(title,$0)} }
            if choice<=0 || choice==5 {return}
            if choice==2 {if let app=try DesktopInstaller.selected(root:root){try NativeInstall.launch(app)};continue}
            if choice==4 {
                let confirm="アプリ本体を削除します。ペット・会話設定は保持します。".withCString {title in "削除する\nキャンセル".withCString {castor_choose_option(title,$0)}}
                if confirm==1 {let old=try DesktopInstaller.selected(root:root);try DesktopInstaller.uninstall(root:root);if let old {NativeInstall.removeLaunchEntry(old)}};continue
            }
            let repair=choice==3,state=SetupWork()
            let job=Task.detached {
                do {
                    let (release,manifest)=try await DesktopInstaller.latest()
                    let app=try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:platform,
                        repair:repair,extract:{try await NativeInstall.extract($0,$1)},stamp:{try NativeInstall.stamp($0)})
                    state.complete(.success(app))
                } catch {state.complete(.failure(error))}
            }
            let status="対応するアプリを取得・検証しています。SHA-256は配布者の真正性を保証しません。OSの安全確認を解除しません。".withCString {
                castor_wait_work($0,{context in Unmanaged<SetupWork>.fromOpaque(context!).takeUnretainedValue().done ? 1 : 0},Unmanaged.passUnretained(state).toOpaque())
            }
            if status<=0 {job.cancel();continue}
            do {
                let app=try state.value()
                do {try NativeInstall.createLaunchEntry(app)} catch {
                    _ = "ショートカットを作れませんでした。既存の同名項目は保持しています。この導入アプリの起動ボタンからCastorを開けます。".withCString {title in "続ける".withCString {castor_choose_option(title,$0)}}
                }
                let launch="導入できました。初回にはSmartScreenの確認が出る場合があります。".withCString {title in "アプリを起動\n後で起動".withCString {castor_choose_option(title,$0)}}
                if launch==1 {try NativeInstall.launch(app)}
            } catch {
                let message=error.localizedDescription
                _ = message.withCString {title in "閉じる（既存アプリ・ペット・設定は保持）".withCString {castor_choose_option(title,$0)}}
            }
        }
    } catch {_ = error.localizedDescription.withCString {title in "閉じる".withCString {castor_choose_option(title,$0)}}}
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
        DispatchQueue.global(qos:.userInteractive).async {setupUI();exit(0)}
        dispatchMain()
    }
}
#elseif os(macOS)
import AppKit
import SwiftUI
@MainActor final class SetupModel: ObservableObject {
    @Published var status="OS/CPUに合うアプリを取得します。既存のペット・設定は保持します。"
    @Published var busy=false
    private var job: Task<Void,Never>?
    func install(repair: Bool=false){
        guard !busy else{return};busy=true;status="取得・検証・導入中..."
        job=Task {
            do {
                let (release,manifest)=try await DesktopInstaller.latest()
                let app=try await DesktopInstaller.install(root:NativeInstall.root,release:release,manifest:manifest,
                    platform:NativeInstall.platform,repair:repair,extract:{try await NativeInstall.extract($0,$1)},stamp:{try NativeInstall.stamp($0)})
                do {try NativeInstall.createLaunchEntry(app);status="Castor \(app.version)を導入しました。ApplicationsのCastor.appから直接起動できます。初回にはmacOSの安全確認が出る場合があります。"}
                catch {status="Castor \(app.version)は導入済みです。同名の既存アプリを保持したため入口を作れませんでした。起動ボタンで開けます。"}
            } catch is CancellationError {status="キャンセルしました。既存アプリとデータは保持しています。"}
            catch {status=error.localizedDescription}
            busy=false;job=nil
        }
    }
    func cancel(){job?.cancel()}
    func launch(){do{if let app=try DesktopInstaller.selected(root:NativeInstall.root){try NativeInstall.launch(app)}}catch{status=error.localizedDescription}}
    func remove(){
        let alert=NSAlert();alert.messageText="アプリ本体を削除しますか？";alert.informativeText="ペット・会話設定は保持します。";alert.addButton(withTitle:"削除");alert.addButton(withTitle:"キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {do{let old=try DesktopInstaller.selected(root:NativeInstall.root);try DesktopInstaller.uninstall(root:NativeInstall.root);if let old{NativeInstall.removeLaunchEntry(old)};status="アプリを削除しました。ペット・設定は保持しています。"}catch{status=error.localizedDescription}}
    }
}
@main struct CastorSetupApp: App {
    @StateObject private var model=SetupModel()
    var body: some Scene {WindowGroup("Castor - 導入・更新・修復") {
        VStack(alignment:.leading,spacing:16){
            Text("Castor").font(.largeTitle.bold());Text(model.status).textSelection(.enabled)
            Text("GitHub Releasesから取得します。SHA-256は同じ配布元の一覧との照合であり、真正性の保証ではありません。Gatekeeperやquarantineを解除しません。")
                .font(.caption).foregroundStyle(.secondary)
            if model.busy {ProgressView();Button("キャンセル"){model.cancel()}}
            else {HStack{Button("取得・更新"){model.install()};Button("起動"){model.launch()};Button("修復"){model.install(repair:true)};Button("アプリを削除"){model.remove()}}}
        }.padding(24).frame(width:570).onAppear{NSApplication.shared.setActivationPolicy(.regular);NSApplication.shared.activate(ignoringOtherApps:true)}
    }.windowResizability(.contentSize)}
}
#else
@main struct UnsupportedSetup { static func main() { print("CastorSetup supports Mac and Windows.") } }
#endif
