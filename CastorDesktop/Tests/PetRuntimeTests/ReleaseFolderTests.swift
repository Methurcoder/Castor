#if os(macOS)
import Foundation
import Testing
@testable import PetRuntime

/// Checks a prepared release folder (prepare-castor-release.py output) the way
/// Castor Setup reads it, before anything is uploaded:
///
///     CASTOR_RELEASE_DIR=/path/to/release [CASTOR_PREVIOUS_RELEASE_DIR=/path/to/previous] swift test --filter ReleaseFolder
///
/// Every package ZIP passes the installer's file rules. On this Mac the app,
/// the speech helper and the feeling model are installed from the folder;
/// with a previous release, its version is installed first and the update
/// must take only the file list and the patch.
private struct LocalRelease {
    let folder: URL
    let release: DesktopRelease
    let manifest: DesktopDownloadManifest

    init(_ path: String) throws {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try JSONDecoder().decode(DesktopDownloadManifest.self, from: Data(contentsOf: folder.appendingPathComponent("castor-downloads.json")))
        self.folder = folder
        self.manifest = manifest
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let assets: [[String: Any]] = try names.map { name in
            let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as! NSNumber
            return ["name": name, "size": size.int64Value,
                    "browser_download_url": "https://github.com/Methurcoder/Castor/releases/download/\(manifest.version)/\(name)"]
        }
        let json: [String: Any] = ["tag_name": manifest.version, "draft": false, "prerelease": false, "assets": assets]
        release = try JSONDecoder().decode(DesktopRelease.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func install(root: URL, component: DesktopHelperComponent?, log: ReleaseDownloads) async throws -> DesktopInstalledApp {
        let folder = folder
        return try await DesktopInstaller.install(root: root, release: release, manifest: manifest, platform: "macos_arm64", component: component,
            extract: { archive, destination in
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", archive.path, destination.path]
                try ditto.run(); ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            },
            stamp: { _ in },
            download: { url, destination in
                log.add(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: folder.appendingPathComponent(url.lastPathComponent), to: destination)
            })
    }
}

private final class ReleaseDownloads: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CASTOR_RELEASE_DIR"]?.isEmpty == false))
func releaseFolderInstallsAndUpdatesLikeSetup() async throws {
    let environment = ProcessInfo.processInfo.environment
    let new = try LocalRelease(environment["CASTOR_RELEASE_DIR"]!)
    let previous = try environment["CASTOR_PREVIOUS_RELEASE_DIR"].flatMap { $0.isEmpty ? nil : $0 }.map(LocalRelease.init)
    let groups: [(DesktopHelperComponent?, [String: DesktopDownloadManifest.Package])] =
        [(nil, new.manifest.platforms)] + DesktopHelperComponent.allCases.compactMap { component in
            new.manifest.components?[component.rawValue].map { (component, $0) }
        }
    for (component, packages) in groups {
        for platform in packages.keys.sorted() {
            let (package, _) = try new.manifest.package(platform: platform, release: new.release, component: component)
            let data = try Data(contentsOf: new.folder.appendingPathComponent(package.asset))
            #expect(PackageIntegrity.sha256(data) == package.sha256, "\(package.asset)")
            try PackageZIP.validate(data, platform: platform, component: component)
            if let patch = package.patch {
                try PackageZIP.validate(Data(contentsOf: new.folder.appendingPathComponent(patch.asset)), platform: platform, component: component)
            }
        }
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("castor-release-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    for (component, _) in groups {
        let root = DesktopInstallLayout.installationRoot(base: base, component: component)
        let stem = component?.stem ?? "Castor"
        var old: DesktopInstalledApp?
        if let previous, previous.manifest.package(platform: "macos_arm64", component: component) != nil {
            old = try await previous.install(root: root, component: component, log: ReleaseDownloads())
        }
        let log = ReleaseDownloads()
        let installed = try await new.install(root: root, component: component, log: log)
        #expect(installed.version == new.manifest.version)
        #expect(try DesktopInstaller.selected(root: root)?.folder == installed.folder)
        if old != nil {
            // An update takes the file list and only the changed files.
            #expect(!log.all.contains("\(stem)-\(new.manifest.version)-macos_arm64.zip"), "\(stem): \(log.all)")
        }
        print("\(stem): \(old.map { "\($0.version) → " } ?? "")\(installed.version), downloaded \(log.all)")
    }
}

private extension DesktopDownloadManifest {
    func package(platform: String, component: DesktopHelperComponent?) -> Package? {
        (component.map { components?[$0.rawValue] ?? [:] } ?? platforms)[platform]
    }
}
#endif
