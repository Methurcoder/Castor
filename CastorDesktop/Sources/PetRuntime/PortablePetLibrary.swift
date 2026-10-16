import Foundation

/// User data, independent of the versioned executable/installer folder.
public struct PortablePetLibrary {
    public enum LibraryError: LocalizedError {
        case notInLibrary, shownOnDesktop
        public var errorDescription: String? {
            switch self {
            case .notInLibrary: "このペットはペット一覧の保存先にないため削除できません。"
            case .shownOnDesktop: "デスクトップに表示中のペットは削除できません。別のペットを表示してから削除してください。"
            }
        }
    }

    /// One saved pet in the library folder.
    public struct Entry: Equatable, Sendable {
        public let file: URL
        public let created: Date
    }

    public let root: URL
    public init(root: URL) { self.root = root }

    public var libraryFolder: URL { root.appendingPathComponent("Library", isDirectory: true) }

    /// Saved pets, newest first.
    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: libraryFolder.path) else { return [] }
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { file in
                let values = try? file.resourceValues(forKeys: Set(keys))
                return Entry(file: file, created: values?.creationDate ?? values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.created > $1.created }
    }

    public func thumbnailFile(for file: URL) -> URL { file.deletingPathExtension().appendingPathExtension("png") }

    /// A small PNG of the pet at rest, cached beside its file.
    public func thumbnail(for file: URL, width: Int = 208, height: Int = 272) throws -> Data {
        let cached = thumbnailFile(for: file)
        if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }
        let player = PetPlayback(asset: try PetSource.loadAsset(contentsOf: file))
        player.automaticTurn = false
        var canvas = PetCanvas(width: width, height: height)
        player.render(into: &canvas, time: 0)
        // Premultiplied BGRA to straight RGBA.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let alpha = Int(canvas.bgra[i * 4 + 3])
            rgba[i * 4 + 3] = UInt8(alpha)
            guard alpha > 0 else { continue }
            for (target, source) in [(0, 2), (1, 1), (2, 0)] {
                rgba[i * 4 + target] = UInt8(min(255, (Int(canvas.bgra[i * 4 + source]) * 255 + alpha / 2) / alpha))
            }
        }
        let data = try PortableRigImage(width: width, height: height, rgba: rgba).pngData()
        try? data.write(to: cached, options: .atomic)
        return data
    }

    /// Recycles a saved pet and its picture; the pet on the desktop is never removed.
    public func remove(_ file: URL, recycle: (URL) throws -> Void) throws {
        guard file.deletingLastPathComponent().standardizedFileURL.path == libraryFolder.standardizedFileURL.path else {
            throw LibraryError.notInLibrary
        }
        if let selected = try selectedFile(), selected.standardizedFileURL.path == file.standardizedFileURL.path {
            throw LibraryError.shownOnDesktop
        }
        try recycle(file)
        let picture = thumbnailFile(for: file)
        if FileManager.default.fileExists(atPath: picture.path) { try? recycle(picture) }
    }

    public func selectedFile() throws -> URL? {
        let selection = root.appendingPathComponent("LastPet.json")
        guard FileManager.default.fileExists(atPath: selection.path) else { return nil }
        let path = try JSONDecoder().decode(String.self, from: Data(contentsOf: selection))
        return URL(fileURLWithPath: path)
    }

    public func remember(_ url: URL) throws {
        // Validate before changing the selection. Existing selection survives failure.
        _ = try PetSource.loadAsset(contentsOf: url)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(url.path).write(to: root.appendingPathComponent("LastPet.json"), options: .atomic)
    }

    @discardableResult
    public func saveNew(_ data: Data) throws -> URL {
        _ = try PetSource.loadAsset(data: data)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let file = library.appendingPathComponent("CastorPet-\(UUID().uuidString).json")
        try data.write(to: file, options: .withoutOverwriting)
        // Failure here leaves a recoverable new library file and the previous selection.
        try remember(file)
        return file
    }
}
