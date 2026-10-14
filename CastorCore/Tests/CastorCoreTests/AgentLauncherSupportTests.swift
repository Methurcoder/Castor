import Foundation
import Testing
@testable import CastorCore

@Test func agentServicesListenOnlyOnThisMac() {
    #expect(AgentLauncherSupport.loopbackEndpoint("ws://127.0.0.1:4500")! == ("127.0.0.1", 4500))
    #expect(AgentLauncherSupport.loopbackEndpoint(" http://localhost:4510 ")! == ("127.0.0.1", 4510))
    // Anything another machine could reach, or without an explicit port, is refused.
    #expect(AgentLauncherSupport.loopbackEndpoint("ws://0.0.0.0:4500") == nil)
    #expect(AgentLauncherSupport.loopbackEndpoint("http://192.168.1.4:4510") == nil)
    #expect(AgentLauncherSupport.loopbackEndpoint("http://127.0.0.1") == nil)
    #expect(AgentLauncherSupport.loopbackEndpoint("http://127.0.0.1:80") == nil)
    #expect(AgentLauncherSupport.loopbackEndpoint("file:///tmp/socket") == nil)
    for value in ["ws://user:pass@127.0.0.1:4500", "http://localhost:4510/path", "http://localhost:4510?q=secret", "ws://localhost:4500#fragment"] {
        #expect(AgentLauncherSupport.loopbackEndpoint(value) == nil)
    }
}

@Test func loginShellPathIsReadFromEnvOutput() {
    let output = """
    zsh: no job control in this shell
    HOME=/example/user
    PATH=/example/user/.local/bin:/opt/homebrew/bin:/usr/bin
    SHELL=/bin/zsh
    """
    #expect(AgentLauncherSupport.path(fromEnvironmentOutput: output) == "/example/user/.local/bin:/opt/homebrew/bin:/usr/bin")
    #expect(AgentLauncherSupport.path(fromEnvironmentOutput: "HOME=/example/user") == nil)
}

@Test func searchPathKeepsShellOrderThenAddsCommonInstallLocations() {
    let path = AgentLauncherSupport.searchPath(shellPath: "/opt/homebrew/bin:/custom/bin", home: "/example/user")
    #expect(path.prefix(2) == ["/opt/homebrew/bin", "/custom/bin"])
    #expect(path.contains("/example/user/.local/bin"))
    #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    // Without a readable shell the common locations still apply.
    #expect(AgentLauncherSupport.searchPath(shellPath: nil, home: "/example/user").first == "/example/user/.local/bin")
}

@Test func launcherStatusRoundTrips() throws {
    let status = AgentLauncherStatus(
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        helperProcessID: 42,
        services: ["codex": .init(state: .ready, detail: "/usr/local/bin/codex")]
    )
    let decoded = try #require(AgentLauncherStatus.decode(status.encoded()))
    #expect(decoded == status)
    #expect(decoded.status(of: .codex)?.state == .ready)
    #expect(decoded.status(of: .claudeCode) == nil)
}
