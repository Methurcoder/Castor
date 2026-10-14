import Foundation

/// A per-launch local control file, confined to Castor's container support folder.
/// It cannot select a process, shell command or arbitrary file to delete.
public nonisolated enum NeuralSpeechHelperControl {
    public enum Command: String, Sendable { case run, stop }
    public nonisolated struct Owner: Codable, Sendable {
        public let parentPID: Int32
        public let helperPath: String
        public init(parentPID: Int32, helperPath: String) { self.parentPID = parentPID; self.helperPath = helperPath }
    }
    private static func ownerFile(_ file: URL) -> URL { file.appendingPathExtension("owner.json") }
    public static func writeOwner(_ owner: Owner, to file: URL) throws {
        guard owner.parentPID > 1, validatedFile(file.path, directory: file.deletingLastPathComponent()) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let metadata = ownerFile(file)
        guard (try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CocoaError(.fileWriteInvalidFileName) }
        try JSONEncoder().encode(owner).write(to: metadata, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        #endif
    }
    public static func owner(_ file: URL, helper: URL) -> Owner? {
        guard validatedFile(file.path, directory: file.deletingLastPathComponent()) != nil else { return nil }
        let metadata = ownerFile(file)
        guard (try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: metadata.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? 4096) < 4096,
              let data = try? Data(contentsOf: metadata), let owner = try? JSONDecoder().decode(Owner.self, from: data),
              owner.parentPID > 1,
              URL(fileURLWithPath: owner.helperPath).standardizedFileURL.resolvingSymlinksInPath().path == helper.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        return owner
    }
    public static func remove(_ file: URL) {
        guard validatedFile(file.path, directory: file.deletingLastPathComponent()) != nil else { return }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: ownerFile(file))
    }
    public static func file(directory: URL, session: UUID) -> URL {
        directory.appendingPathComponent(session.uuidString + ".control")
    }
    public static func validatedFile(_ path: String, directory: URL) -> URL? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.standardizedFileURL.path,
              file.pathExtension == "control", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return file
    }
    public static func write(_ command: Command, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        #if os(Windows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        #endif
        guard validatedFile(file.path, directory: directory) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try Data(command.rawValue.utf8).write(to: file, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #endif
    }
    public static func read(_ file: URL) -> Command? {
        guard validatedFile(file.path, directory: file.deletingLastPathComponent()) != nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? 256) < 16,
              let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }
        return Command(rawValue: text)
    }
}
