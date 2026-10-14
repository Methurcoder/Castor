import Foundation
#if canImport(os)
import os
#endif

/// Minimal logging facade. Uses `os.Logger` on Apple platforms (every message is public, matching
/// the previous call sites) and falls back to standard error elsewhere.
public nonisolated struct CastorLog: Sendable {
    public static let defaultSubsystem = "dev.pomegranate.prototype"

    #if canImport(os)
    private let logger: Logger
    #else
    private let label: String
    #endif

    public init(subsystem: String = CastorLog.defaultSubsystem, category: String) {
        #if canImport(os)
        logger = Logger(subsystem: subsystem, category: category)
        #else
        label = "[\(subsystem):\(category)]"
        #endif
    }

    public func info(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #else
        write("info", message)
        #endif
    }

    public func notice(_ message: String) {
        #if canImport(os)
        logger.notice("\(message, privacy: .public)")
        #else
        write("notice", message)
        #endif
    }

    /// Formats a number with a fixed number of fraction digits, replacing os.Logger's
    /// `format: .fixed(precision:)` so messages read the same on every platform.
    public static func fixed(_ value: Double, precision: Int = 2) -> String {
        String(format: "%.\(precision)f", value)
    }

    #if !canImport(os)
    private func write(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("\(label) \(level): \(message)\n".utf8))
    }
    #endif
}
