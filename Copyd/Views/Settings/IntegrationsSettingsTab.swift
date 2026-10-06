import SwiftUI

/// Settings > Integrations: the local MCP server that lets AI tools search and read clips (spec §4).
struct IntegrationsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage(MCPServer.enabledDefaultsKey) private var enabled = false
    @AppStorage(MCPServer.portDefaultsKey) private var port = MCPServer.defaultPort
    @AppStorage(MCPServer.allowsWriteDefaultsKey) private var allowsWrite = false
    /// Committed to `port` only within `MCPServer.ports`; anything else reverts.
    @State private var portField = MCPServer.defaultPort
    @State private var confirmsRegenerate = false

    private var status: String {
        switch appState.mcpState {
        case .off:
            // Its own key: plain "Off" is the sync status, which reads differently in Spanish.
            String(localized: "MCP.status.off", defaultValue: "Off", comment: "Settings > Integrations: the MCP server isn't running")
        case .running(let port):
            String(localized: "Running on 127.0.0.1:\(String(port))")
        case .portInUse(let port):
            String(localized: "Port \(String(port)) is in use")
        case .failed(let message):
            String(localized: "Couldn't start the server: \(message)")
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Copyd MCP server", isOn: $enabled)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: enabled) { _, _ in appState.applyMCPSettings() }

                TextField("Port", value: $portField, format: .number.grouping(.never))
                    .onChange(of: portField) { _, value in
                        guard MCPServer.ports.contains(value) else { portField = MCPServer.savedPort; return }
                        guard value != MCPServer.savedPort else { return }
                        port = value
                        appState.applyMCPSettings()
                    }

                LabeledContent("Access token") {
                    HStack {
                        Text(verbatim: appState.mcpToken == nil ? "\u{2014}" : String(repeating: "\u{2022}", count: 16))
                            .foregroundStyle(.secondary)
                        Button("Copy") { if let token = appState.mcpToken { copy(token) } }
                            .disabled(appState.mcpToken == nil)
                        // Only once a token exists: the first one is made when the server is first switched on.
                        Button("Regenerate") { confirmsRegenerate = true }
                            .disabled(appState.mcpToken == nil)
                    }
                }
                .confirmationDialog("Regenerate the token?", isPresented: $confirmsRegenerate) {
                    Button("Regenerate", role: .destructive) { appState.regenerateMCPToken() }
                } message: {
                    Text("Apps using the current token will stop connecting.")
                }

                Toggle("Allow writing to the clipboard", isOn: $allowsWrite)
                    // `tools/list` says its list never changes: a restart makes clients list the tools again.
                    .onChange(of: allowsWrite) { _, _ in appState.applyMCPSettings() }
            } footer: {
                Text("Only apps on this Mac can connect, and only with the token. Secrets are never shared.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Copy Claude Code command") {
                        if let token = appState.mcpToken { copy(MCPToken.claudeCodeCommand(port: MCPServer.savedPort, token: token)) }
                    }
                    Button("Copy Cursor config") {
                        if let token = appState.mcpToken { copy(MCPToken.cursorConfig(port: MCPServer.savedPort, token: token)) }
                    }
                }
                .disabled(appState.mcpToken == nil)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            portField = MCPServer.savedPort
            appState.loadMCPToken()
        }
    }

    /// Skipped by the monitor, and concealed for other clipboard managers: the token never lands in a history.
    private func copy(_ text: String) {
        appState.clipboardMonitor.skipStagedChange()
        MCPToken.copyConcealed(text)
    }
}
