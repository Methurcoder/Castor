import Foundation

/// User data, independent of the versioned executable/installer folder.
public struct PortablePetLibrary {
    public let root: URL
    public init(root: URL) { self.root = root }

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
