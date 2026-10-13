import AppKit
import SwiftUI

/// Settings › AI Tools: whether AI tools such as Claude Code may connect to
/// Quill's local MCP server, and how to register it. The server is off until
/// the switch is turned on; what a connected tool receives is shown next to
/// the switch, so turning it on is the consent (#528).
struct AIToolsSettingsView: View {
    @EnvironmentObject var appState: AppState

    static let claudeCodeCommand = "claude mcp add -s user -t http quill \(MCPServer.address)"

    var body: some View {
        SettingsPageScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Tools")
                    .font(.largeTitle.bold())

                SettingsCard("AI Tool Connection (MCP)", icon: "link") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Allow AI tools like Claude Code to connect to Quill", isOn: $appState.isMCPServerEnabled)
                            .toggleStyle(.switch)
                        Text(ConnectionsChoices.mcpDisclosure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        statusRow
                    }
                }

                if appState.isMCPServerEnabled,
                   appState.mcpServerStatus == .listening || appState.mcpServerStatus == .starting {
                    SettingsCard("Connect Claude Code", icon: "terminal") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Run this command once in Terminal. If you already registered Quill, you don't need to again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Text(verbatim: Self.claudeCodeCommand)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(Self.claudeCodeCommand, forType: .string)
                                }
                            }
                            Text("Claude Code sessions that were already open: reconnect with /mcp, or open a new session.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            statusText
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch appState.mcpServerStatus {
        case .listening: return .green
        case .failed: return .orange
        case .off, .starting: return .secondary
        }
    }

    private var statusText: Text {
        switch appState.mcpServerStatus {
        case .off where appState.isMCPServerEnabled:
            // Only before setup is finished: the server starts after it.
            return Text("Starts when setup is finished.")
        case .off:
            return Text("Off. When on, Quill waits for connections at \(MCPServer.address), from this Mac only.")
        case .starting:
            return Text("Starting…")
        case .listening:
            return Text("Waiting for connections at \(MCPServer.address), from this Mac only.")
        case .failed:
            return Text("Couldn't start. Another app may be using port \(String(MCPServer.port)). Turn the switch off and on to try again.")
        }
    }
}
