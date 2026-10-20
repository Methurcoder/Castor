import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where CastorSetup keeps installed versions on a Mac, and the one entry
/// people open.
///
/// Launchpad lists every app under ~/Applications, links included, so version
/// folders kept there each showed up as one more Castor (two after the first
/// install, three after an update). Versions now live in
/// ~/Library/Application Support/Castor/Versions, and ~/Applications holds only
/// the Castor.app link to the selected version, plus CastorNeuralTTS.app once
/// the optional helper is installed: Castor opens the helper by that path.
/// Windows keeps %LOCALAPPDATA%\Programs\Castor and is not affected.
public enum DesktopInstallLayout {
    public enum LayoutError: Error { case notSelected, occupied }

    /// The folder people open apps from, where the launch links go.
    public static func macLaunchFolder(home:URL)->URL {home.appendingPathComponent("Applications",isDirectory:true)}
    /// Where installed versions are kept.
    public static func macVersionsRoot(home:URL)->URL {
        home.appendingPathComponent("Library/Application Support/Castor/Versions",isDirectory:true)
    }
    /// Where Setup kept versions up to v1.0.0.
    public static func macLegacyRoot(home:URL)->URL {macLaunchFolder(home:home)}
    /// The install root of the app (`component` nil) or of a helper under `base`.
    public static func installationRoot(base:URL,component:DesktopHelperComponent?)->URL {
        component.map {base.appendingPathComponent("CastorHelpers/"+$0.rawValue,isDirectory:true)} ?? base
    }

    /// `root` once it has a selected version. Until then, `legacyRoot` while
    /// the version an older Setup selected there is still in place, so Launch
    /// and Remove keep working before the first update.
    public static func selectedRoot(root:URL,legacyRoot:URL?)->URL {
        if (try? DesktopInstaller.selected(root:root)) != nil {return root}
        guard let legacyRoot,let app=try? DesktopInstaller.selected(root:legacyRoot),
              FileManager.default.fileExists(atPath:legacyRoot.appendingPathComponent(app.folder).path) else {return root}
        return legacyRoot
    }

    #if !os(Windows)
    /// Points `<launchFolder>/<stem>.app` at the selected version in `root`.
    ///
    /// An item already there is replaced only when it is a link this installer
    /// made: into `root`, or into one of `legacyRoots` at a version folder that
    /// is gone or carries this installer's record. Anything else, such as a
    /// copy of the app or a link elsewhere, is kept and this throws.
    public static func linkLaunchEntry(_ app:DesktopInstalledApp,root:URL,launchFolder:URL,legacyRoots:[URL]=[]) throws {
        guard try DesktopInstaller.selected(root:root)?.folder==app.folder else {throw LayoutError.notSelected}
        let stem=app.component?.stem ?? "Castor"
        let link=launchFolder.appendingPathComponent(stem+".app")
        let target=root.appendingPathComponent(app.folder).appendingPathComponent(stem+".app")
        let manager=FileManager.default
        if let existing=try? manager.destinationOfSymbolicLink(atPath:link.path) {
            guard replaceable(existing,link:link,app:app,root:root,legacyRoots:legacyRoots) else {throw LayoutError.occupied}
        } else if manager.fileExists(atPath:link.path) {throw LayoutError.occupied}
        try manager.createDirectory(at:launchFolder,withIntermediateDirectories:true)
        let staged=launchFolder.appendingPathComponent(".castor-link-\(UUID().uuidString)")
        defer {try? manager.removeItem(at:staged)}
        try manager.createSymbolicLink(at:staged,withDestinationURL:target)
        // One rename, so the entry is never missing while it is replaced.
        guard staged.path.withCString({source in link.path.withCString {rename(source,$0)}})==0 else {throw LayoutError.occupied}
    }

    private static func replaceable(_ destination:String,link:URL,app:DesktopInstalledApp,root:URL,legacyRoots:[URL])->Bool {
        let stem=app.component?.stem ?? "Castor"
        let old=(destination.hasPrefix("/") ? URL(fileURLWithPath:destination)
                 : link.deletingLastPathComponent().appendingPathComponent(destination)).standardizedFileURL
        let folder=old.deletingLastPathComponent(),parent=folder.deletingLastPathComponent().path
        guard old.lastPathComponent==stem+".app",folder.lastPathComponent.hasPrefix(stem+"-") else {return false}
        // The versions folder holds only this installer's (and the script downloader's) versions.
        if parent==root.standardizedFileURL.path {return true}
        guard legacyRoots.contains(where:{$0.standardizedFileURL.path==parent}) else {return false}
        // Its version folder has already gone to the Trash.
        if !FileManager.default.fileExists(atPath:folder.path) {return true}
        guard let record=try? DesktopInstaller.readRecord(folder.appendingPathComponent("CastorInstall.json")) else {return false}
        return record.component==app.component && record.folder==folder.lastPathComponent
    }

    /// Removes `<launchFolder>/<stem>.app` only when it points at `app` in `root`.
    public static func removeLaunchEntry(_ app:DesktopInstalledApp,root:URL,launchFolder:URL) {
        let stem=app.component?.stem ?? "Castor"
        let link=launchFolder.appendingPathComponent(stem+".app")
        let target=root.appendingPathComponent(app.folder).appendingPathComponent(stem+".app")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath:link.path))==target.path {try? FileManager.default.removeItem(at:link)}
    }
    #endif

    /// Sends the version folders an older Setup kept in `legacyRoot` to the
    /// Trash with `trash` once `root` has a selected version, so Launchpad
    /// stops listing them.
    ///
    /// Only folders carrying this installer's own record are moved; anything
    /// else is left alone, and so is a folder `trash` leaves in place (one that
    /// is running), which a later run retries. When none is left, the old
    /// bookkeeping (selection records, lock, unfinished download) goes to the
    /// Trash too, and `emptyFolders` are removed in order while empty.
    /// Characters and settings never live in these folders.
    @discardableResult
    public static func retireLegacyVersions(legacyRoot:URL,root:URL,component:DesktopHelperComponent?,emptyFolders:[URL]=[],
                                            trash:(URL) throws -> Void) throws -> Int {
        let manager=FileManager.default
        guard legacyRoot.standardizedFileURL.path != root.standardizedFileURL.path,
              let current=try? DesktopInstaller.selected(root:root),current.component==component,
              manager.fileExists(atPath:root.appendingPathComponent(current.folder).path) else {return 0}
        let meta=DesktopInstaller.metadataRoot(root:legacyRoot)
        let receipt=legacyRoot.appendingPathComponent("CurrentInstall.json")
        guard !legacyVersions(legacyRoot,component).isEmpty || manager.fileExists(atPath:meta.path)
                || manager.fileExists(atPath:receipt.path) else {return 0}
        var count=0
        do {
            // An older Setup still working on the old place holds this lock.
            let lease=try DesktopInstaller.lock(root:legacyRoot);defer {lease.release()}
            for folder in legacyVersions(legacyRoot,component) {
                try trash(folder);if !manager.fileExists(atPath:folder.path) {count+=1}
            }
            guard legacyVersions(legacyRoot,component).isEmpty else {return count}
            if (try? DesktopInstaller.readRecord(receipt)) != nil {try trash(receipt)}
            try trash(meta)
        }
        for folder in emptyFolders {
            guard let items=try? manager.contentsOfDirectory(atPath:folder.path),items.allSatisfy({$0==".DS_Store"}) else {break}
            try? manager.removeItem(at:folder)
        }
        return count
    }

    /// Version folders in `legacyRoot` that carry this installer's record.
    private static func legacyVersions(_ legacyRoot:URL,_ component:DesktopHelperComponent?)->[URL] {
        let stem=component?.stem ?? "Castor"
        let items=(try? FileManager.default.contentsOfDirectory(at:legacyRoot,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])) ?? []
        return items.filter { folder in
            guard folder.lastPathComponent.hasPrefix(stem+"-"),
                  let flags=try? folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),
                  flags.isDirectory==true,flags.isSymbolicLink != true,
                  let record=try? DesktopInstaller.readRecord(folder.appendingPathComponent("CastorInstall.json")) else {return false}
            return record.folder==folder.lastPathComponent && record.component==component
        }.sorted {$0.lastPathComponent<$1.lastPathComponent}
    }
}
