import AgentFloatCore
import AppKit
import SwiftUI

/// Render the same production components as the Korean guide without opening app windows.
@MainActor
struct IdentityExample: View {
    let dark: Bool
    let now: Date

    private func session(_ id: String, _ agent: String, _ title: String, _ status: AgentStatus, _ reason: WaitReason? = nil) -> AgentSession {
        AgentSession(
            key: SessionKey(providerId: agent == "Claude" ? "claude-code" : "codex", sessionId: id),
            agentName: agent, title: title, cwd: "/demo/agent-float", status: status,
            waitReason: reason, statusSince: now.addingTimeInterval(-120), isStale: false,
            lastActivityAt: nil, terminalApp: .orca, locator: .none
        )
    }

    private var claude: AgentSession { session("checkout", "Claude", "Improve checkout screen", .waiting, .question) }
    private var codex: AgentSession { session("detection", "Codex", "Add session detection", .waiting, .bodyQuestion) }
    private var running: AgentSession { session("network", "Codex", "Duplicate responses after reconnecting", .running) }
    private var done: AgentSession { session("regression", "Claude", "Extend regression coverage", .done) }
    private var surface: Color { dark ? Color(white: 0.16) : .white }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Agent Float · Agent identity")
                .font(.system(size: 20, weight: .bold))
            HStack(alignment: .top, spacing: 25) {
                VStack(alignment: .leading, spacing: 12) {
                    label("Session list · 280px")
                    SessionListContent(
                        groups: [
                            SessionGroup(status: .waiting, sessions: [claude, codex]),
                            SessionGroup(status: .running, sessions: [running]),
                            SessionGroup(status: .done, sessions: [done]),
                        ],
                        unseen: [done.key], now: now, canNavigate: { _ in true }, onActivate: { _ in }
                    )
                    .frame(width: Layout.listWidth)
                    .padding(Layout.panelPadding)
                    .background(surface, in: RoundedRectangle(cornerRadius: Layout.panelCornerRadius))
                }
                .frame(width: Layout.panelWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    label("Reply header · 320px")
                    VStack(alignment: .leading, spacing: 0) {
                        ReplyHeader(session: codex, isLocked: false, onBack: {})
                        Text("Which scope should we update?")
                            .font(.system(size: 13))
                            .padding(10)
                            .padding(.top, ReplyLayout.navToContent)
                    }
                    .padding(6)
                    .frame(width: ReplyLayout.width, alignment: .leading)
                    .background(surface, in: RoundedRectangle(cornerRadius: Layout.panelCornerRadius))
                    label("Side card · Keep the agent context")
                    VStack(alignment: .leading, spacing: 12) {
                        AgentBadge(session: claude)
                        Text("The agent name stays visible; the project name truncates first.")
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(width: ReplyLayout.width, alignment: .leading)
                    .background(surface, in: RoundedRectangle(cornerRadius: Layout.panelCornerRadius))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(width: 685, height: 393, alignment: .topLeading)
        .background(dark ? Color(white: 0.10) : Color(white: 0.94))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func label(_ value: String) -> some View {
        Text(value).font(.system(size: 13)).foregroundStyle(.secondary)
    }
}

@main
struct IdentityRenderer {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let renderer = ImageRenderer(content: IdentityExample(dark: dark, now: Date()))
            renderer.scale = 2
            guard let cgImage = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let image = NSBitmapImageRep(cgImage: cgImage)
            guard let data = image.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let filename = "agent-identity-\(dark ? "dark" : "light").png"
            try data.write(to: output.appendingPathComponent(filename))
            print("Rendered \(filename): \(image.pixelsWide)×\(image.pixelsHigh)")
        }
    }
}
