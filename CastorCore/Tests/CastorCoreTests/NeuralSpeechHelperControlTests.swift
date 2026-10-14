import Foundation
import Testing
@testable import CastorCore

@Test func speechControlRoundTripsAndIsConfinedToOneSession() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = NeuralSpeechHelperControl.file(directory: root, session: UUID())
    try NeuralSpeechHelperControl.write(.run, to: file)
    #expect(NeuralSpeechHelperControl.read(file) == .run)
    try NeuralSpeechHelperControl.write(.stop, to: file)
    #expect(NeuralSpeechHelperControl.read(file) == .stop)
    #expect(NeuralSpeechHelperControl.validatedFile(file.path, directory: root) == file)
    #expect(NeuralSpeechHelperControl.validatedFile(file.path, directory: root.appendingPathComponent("other")) == nil)
    #expect(NeuralSpeechHelperControl.validatedFile(root.appendingPathComponent("not-a-session.control").path, directory: root) == nil)
    try Data(repeating: 65, count: 1024).write(to: file)
    #expect(NeuralSpeechHelperControl.read(file) == nil)
}

@Test func speechControlRejectsSymlinksAndUnknownCommands() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = NeuralSpeechHelperControl.file(directory: root, session: UUID())
    let other = root.appendingPathComponent("other")
    try Data("run".utf8).write(to: other)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
    #expect(NeuralSpeechHelperControl.validatedFile(file.path, directory: root) == nil)
    #expect(NeuralSpeechHelperControl.read(file) == nil)
    #expect(throws: (any Error).self) { try NeuralSpeechHelperControl.write(.stop, to: file) }
    try FileManager.default.removeItem(at: file)
    try Data("arbitrary command".utf8).write(to: file)
    #expect(NeuralSpeechHelperControl.read(file) == nil)
    #expect(try String(contentsOf: other, encoding: .utf8) == "run")
}

@Test func speechControlOwnerMatchesOnlyItsExactHelper() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = NeuralSpeechHelperControl.file(directory: root, session: UUID())
    let helper = root.appendingPathComponent("helper.app")
    try NeuralSpeechHelperControl.write(.run, to: file)
    try NeuralSpeechHelperControl.writeOwner(.init(parentPID: 42, helperPath: helper.path), to: file)
    #expect(NeuralSpeechHelperControl.owner(file, helper: helper)?.parentPID == 42)
    #expect(NeuralSpeechHelperControl.owner(file, helper: root.appendingPathComponent("other.app")) == nil)
    #expect(throws: (any Error).self) { try NeuralSpeechHelperControl.writeOwner(.init(parentPID: 0, helperPath: helper.path), to: file) }
    NeuralSpeechHelperControl.remove(file)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(NeuralSpeechHelperControl.owner(file, helper: helper) == nil)
}
