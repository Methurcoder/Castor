import ArilsEx
import CoreGraphics
import Darwin
import Foundation
import ImageIO

private struct VisibilityAuditReport: Codable {
    var image: String
    var role: String
    var directVisionJoints: [String]
    var templateJoints: [String]
    var decisions: [OcclusionTopologyDecision]
    var metrics: VisibilityAuditMetrics
    var legacyArmParts: [String]
    var layeredArmParts: [String]
    var admissionAccepted: Bool
    var admissionIssues: [String]
}

@main
private enum ArilsExVisibilityCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let imagePath = arguments.first else {
                throw CommandError.usage
            }
            let role = try parseRole(arguments.dropFirst().first)
            let hiddenSide = try parseHiddenSide(arguments)
            let visibleSide = try parseSide(after: "--visible", in: arguments)
            let image = try loadImage(at: imagePath)
            let engine = JointProposalEngine()
            var pose = await engine.propose(
                for: image,
                role: role,
                fileName: URL(fileURLWithPath: imagePath).lastPathComponent
            )
            if let hiddenSide {
                for joint in OcclusionTopology.armJoints(hiddenSide) {
                    pose.setUserVisibility(.occluded, for: joint)
                }
            }
            if let visibleSide {
                pose.setUserVisibility(.visible, for: .neck)
                for joint in OcclusionTopology.armJoints(visibleSide) {
                    pose.setUserVisibility(.visible, for: joint)
                }
            }
            let topology = OcclusionTopology.resolve([pose])
            guard let resolved = topology.pose(for: role) else {
                throw CommandError.noPose
            }
            let compiler = ArticulationCompiler()
            let subjectMask = try await compiler.subjectMask(for: image)
            let admission = PoseAdmission.evaluate(
                pose: resolved,
                subjectMask: subjectMask
            )
            let report = VisibilityAuditReport(
                image: imagePath,
                role: role.rawValue,
                directVisionJoints: jointNames(in: resolved) { $0.source == .vision },
                templateJoints: jointNames(in: resolved) {
                    $0.source == .silhouetteTemplate
                },
                decisions: topology.decisions,
                metrics: VisibilityAuditMetrics(
                    pose: resolved,
                    joints: JointScope.bustUp.joints
                ),
                legacyArmParts: ArticulationPartID.allCases.map(\.rawValue),
                layeredArmParts: ArticulationPartID.allCases
                    .filter { $0.hasVisibleTexture(in: resolved) }
                    .map(\.rawValue),
                admissionAccepted: admission.isAdmitted,
                admissionIssues: admission.issues.map(\.message)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func parseRole(_ raw: String?) throws -> ReferenceRole {
        guard let raw else { return .right }
        guard let role = ReferenceRole(rawValue: raw) else {
            throw CommandError.invalidRole(raw)
        }
        return role
    }

    private static func parseHiddenSide(_ arguments: [String]) throws -> ArmSide? {
        try parseSide(after: "--occluded", in: arguments)
    }

    private static func parseSide(
        after option: String,
        in arguments: [String]
    ) throws -> ArmSide? {
        guard let flag = arguments.firstIndex(of: option) else { return nil }
        let valueIndex = arguments.index(after: flag)
        guard valueIndex < arguments.endIndex else { throw CommandError.usage }
        guard let side = ArmSide(rawValue: arguments[valueIndex]) else {
            throw CommandError.invalidSide(arguments[valueIndex])
        }
        return side
    }

    private static func loadImage(at path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CommandError.unreadableImage(path)
        }
        return image
    }

    private static func jointNames(
        in pose: ReferencePose,
        where predicate: (JointObservation) -> Bool
    ) -> [String] {
        JointKind.allCases.compactMap { joint in
            guard let observation = pose[joint], predicate(observation) else { return nil }
            return joint.rawValue
        }
    }
}

private enum CommandError: LocalizedError {
    case usage
    case invalidRole(String)
    case invalidSide(String)
    case unreadableImage(String)
    case noPose

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: arils-ex-visibility <image> [left|front|right] [--occluded left|right] [--visible left|right]"
        case let .invalidRole(value):
            "Unknown reference role: \(value)"
        case let .invalidSide(value):
            "Unknown arm side: \(value)"
        case let .unreadableImage(path):
            "Cannot read image: \(path)"
        case .noPose:
            "Visibility topology returned no pose."
        }
    }
}
