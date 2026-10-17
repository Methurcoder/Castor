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

@Test func codexProviderErrorsShowTheirNestedMessage() {
    let raw = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-6-luna' model is not supported when using Codex with a ChatGPT account."}}"#
    #expect(CodexAppServerError.readable(raw) == "The 'gpt-6-luna' model is not supported when using Codex with a ChatGPT account.")
    #expect(CodexAppServerError.turnFailed(raw).errorDescription == CodexAppServerError.readable(raw))
    #expect(CodexAppServerError.readable("Plain text stays.") == "Plain text stays.")
}

@MainActor @Test func codexFallsBackToAnOfferedModelOnlyWhenTheConfiguredOneIsNotOffered() {
    let offered = [(model: "gpt-5.6-terra", isDefault: false), (model: "gpt-5.6-sol", isDefault: true)]
    // The configured default this account cannot use: start with the offered default.
    #expect(CodexAppServerSession.modelOverride(configured: "gpt-6-luna", offered: offered) == "gpt-5.6-sol")
    // A configured model the account is offered, or none at all, is left to Codex.
    #expect(CodexAppServerSession.modelOverride(configured: "gpt-5.6-terra", offered: offered) == nil)
    #expect(CodexAppServerSession.modelOverride(configured: nil, offered: offered) == nil)
    // Without a model list, nothing is guessed.
    #expect(CodexAppServerSession.modelOverride(configured: "gpt-6-luna", offered: []) == nil)
}
