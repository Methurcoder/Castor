import Foundation

public enum ScreenshotLocation {
    public static func current() -> URL {
        if let configured = configuredLocation(),
           FileManager.default.fileExists(atPath: configured.path) {
            return configured
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private static func configuredLocation() -> URL? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.screencapture", "location"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard var path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }
            path = NSString(string: path).expandingTildeInPath
            return URL(fileURLWithPath: path, isDirectory: true)
        } catch {
            return nil
        }
    }
}

public enum ScreenshotFileClassifier {
    public static let supportedExtensions = Set(["png", "jpg", "jpeg", "heic", "tif", "tiff"])

    public static func isLikelyScreenshot(_ url: URL) -> Bool {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let knownPrefixes = [
            "screenshot",
            "screen shot",
            "スクリーンショット",
            "capture d’écran",
            "captura de pantalla",
            "bildschirmfoto",
        ]
        return knownPrefixes.contains { name.hasPrefix($0) }
    }
}
