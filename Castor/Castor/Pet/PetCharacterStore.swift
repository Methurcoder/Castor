import AppKit
import Foundation
import CastorCore
import Arils

/// Pets saved before official characters were removed carry only an `officialCharacterID` key.
/// Unknown keys are ignored when decoding, so such a payload decodes with no image and is treated
/// as "no saved pet" instead of failing.
struct SavedPetCharacter: Codable {
    var document: RigDocument?
    var imageData: Data?
    /// Serialized Arils `AvatarArchive` (rig + part textures). When present,
    /// the floating pet renders through the Arils engine instead of
    /// `RiggedCharacterRenderer`. Optional so older saved pets keep decoding.
    var arilsArchiveData: Data?
    /// Serialized Arils `QualityAvatarArchive` (front + side views). Preferred
    /// over `arilsArchiveData` when present. Optional for the same reason.
    var qualityArchiveData: Data?
    /// The user-selected evasion style for this character.
    var evasionStyle: EvasionStyle? = nil

    var image: NSImage? {
        guard let imageData else {
            return nil
        }
        return NSImage(data: imageData)
    }

    var resolvedEvasionStyle: EvasionStyle {
        evasionStyle ?? .calm
    }
}

enum PetCharacterStore {
    private static let fileName = "CastorPet.json"

    static var fileURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return fileURL(in: baseURL)
    }

    static func fileURL(in baseURL: URL) -> URL {
        return baseURL
            .appendingPathComponent("Castor", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func save(
        image: NSImage,
        document: RigDocument,
        arilsArchiveData: Data? = nil,
        qualityArchiveData: Data? = nil
    ) throws {
        guard let imageData = image.tiffRepresentation else {
            throw CocoaError(.fileWriteUnknown)
        }

        let payload = SavedPetCharacter(
            document: document,
            imageData: imageData,
            arilsArchiveData: arilsArchiveData,
            qualityArchiveData: qualityArchiveData,
            evasionStyle: PetEvasionStyleStore.importedStyle
        )
        try write(payload)
    }

    static func updateImportedEvasionStyle(_ style: EvasionStyle) throws {
        guard var payload = load() else { return }
        payload.evasionStyle = style
        try write(payload)
    }

    /// Accept the same saved-pet JSON on both platforms, including portable Windows rigs.
    static func decodedImportedPet(_ data: Data) throws -> SavedPetCharacter {
        let payload = try JSONDecoder().decode(SavedPetCharacter.self, from: data)
        guard payload.image != nil else { throw CocoaError(.coderReadCorrupt) }
        if let qualityData = payload.qualityArchiveData {
            let quality = try QualityAvatarArchive(data: qualityData)
            _ = try quality.front.makeAvatar()
            _ = try quality.side.makeAvatar()
        } else if let archiveData = payload.arilsArchiveData {
            _ = try AvatarArchive(data: archiveData).makeAvatar()
        } else if payload.document == nil {
            throw CocoaError(.coderValueNotFound)
        }
        return payload
    }

    static func importSavedPet(from url: URL) throws {
        let payload = try decodedImportedPet(Data(contentsOf: url))
        // Keep the previous current pet as a library entry before a deliberate import.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let previous = try Data(contentsOf: fileURL)
            let library = fileURL.deletingLastPathComponent().appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try previous.write(to: library.appendingPathComponent("CastorPet-\(UUID().uuidString).json"),
                               options: .withoutOverwriting)
        }
        try write(payload)
    }

    private static func write(_ payload: SavedPetCharacter) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(payload)

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func load() -> SavedPetCharacter? {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return load(in: baseURL)
    }

    /// Read old pets in the existing sandbox without moving or overwriting them.
    /// Once Castor has saved a new pet, that file takes precedence.
    static func load(in baseURL: URL) -> SavedPetCharacter? {
        let currentURL = fileURL(in: baseURL)
        let legacyURL = baseURL.appendingPathComponent("Pomegranate", isDirectory: true)
            .appendingPathComponent("PomegranatePet.json")
        let sourceURL = FileManager.default.fileExists(atPath: currentURL.path) ? currentURL : legacyURL
        guard let data = try? Data(contentsOf: sourceURL) else {
            return nil
        }

        return try? JSONDecoder().decode(SavedPetCharacter.self, from: data)
    }
}

enum PetDraftStore {
    private static let key = "Pomegranate.PetDraftText"

    static func load() -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func save(_ text: String) {
        UserDefaults.standard.set(text, forKey: key)
    }
}
