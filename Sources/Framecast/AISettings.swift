import SwiftUI
import AppKit

/// Settings › AI: the API key the live brain uses during a show, the optional "Write it for me" (scripts, off by
/// default), and the control link for Claude and other MCP apps on this Mac. Preparing a show from a brief uses
/// Claude on the presenter's own plan, never this key.
struct AIPane: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    @Local var draftKey = ""
    @Local var keySaved = false
    var body: some View {
        let provider = settings.s.aiProvider ?? .claude
        SettingsGroup(title: "Your API key",
                      footer: "Only the live brain uses this key, while you're live and talking: about $0.10–0.50 per show-hour on the default model. Preparing a show from a brief is done by Claude on your own Claude plan (Claude Desktop or Claude Code), not with this key. The service bills your own account; Framecast adds nothing.") {
            SettingRow(title: "Service") {
                Picker("", selection: Binding(get: { provider }, set: { settings.s.aiProvider = $0; draftKey = ""; keySaved = false })) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            SettingRow(title: "API key", detail: AIKeys.has(provider) || keySaved ? "Saved in your Keychain." : "Make one in your \(provider.company) account, then paste it here.") {
                HStack(spacing: 8) {
                    SecureField(provider.keyHint, text: $draftKey).textFieldStyle(.roundedBorder).frame(width: 170)
                    Button("Save") { AIKeys.set(provider, draftKey); draftKey = ""; keySaved = true }.disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if AIKeys.has(provider) || keySaved {
                        Button("Remove") { AIKeys.set(provider, ""); keySaved = false }
                    } else {
                        Button("Get a key") { NSWorkspace.shared.open(provider.keyPage) }
                    }
                }.fixedSize()
            }
        }
        SettingsGroup(title: "Live brain (during a show)",
                      footer: "For shows planned from a brief: every few seconds while you talk, Framecast sends this model the outline and the last 90 seconds of what you said (as text, never audio) and it decides the topic and the visuals.") {
            SettingRow(title: "Model", detail: "Leave empty for \(LiveBrain.defaultModel(provider)), a fast, low-cost model.") {
                TextField(LiveBrain.defaultModel(provider), text: Binding(
                    get: { (provider == .claude ? settings.s.brainClaudeModel : settings.s.brainOpenAIModel) ?? "" },
                    set: { v in if provider == .claude { settings.s.brainClaudeModel = v } else { settings.s.brainOpenAIModel = v } }))
                .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        }
        SettingsGroup(title: "Write it for me (optional)",
                      footer: "Off by default. For word-for-word scripts only: the Rundown's Write it for me button sends the script, title and scene names to the service above, once per click (a few cents on the larger model). Leave it off if Claude prepares your shows.") {
            SettingRow(title: "Use my API key to turn a script into parts") {
                Toggle("", isOn: Binding(get: { settings.s.writeWithAPI ?? false }, set: { settings.s.writeWithAPI = $0 })).toggleStyle(.switch).labelsHidden()
            }
            if settings.s.writeWithAPI ?? false {
                SettingRow(title: "Model", detail: "Leave empty for \(provider.defaultModel).") {
                    TextField(provider.defaultModel, text: Binding(
                        get: { (provider == .claude ? settings.s.claudeModel : settings.s.openAIModel) ?? "" },
                        set: { v in if provider == .claude { settings.s.claudeModel = v } else { settings.s.openAIModel = v } }))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
        }
        ControlLinkGroup()
        SettingsGroup(title: "Following your voice",
                      footer: "Listen uses Apple's on-device speech recognition (macOS 26 or later); your voice never leaves this Mac. Hinglish runs English (India) and Hindi recognition together and the live brain reads both; the Hindi model downloads from Apple once. Each show's decisions are logged in its folder.") {
            SettingRow(title: "Language you speak") {
                Picker("", selection: Binding(get: { settings.s.listenLanguage ?? .auto }, set: { settings.s.listenLanguage = $0 })) {
                    ForEach(ListenLanguage.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 230)
            }
        }
    }
}

struct ControlLinkGroup: View {
    @Environment(Studio.self) var studio
    @Environment(AppSettings.self) var settings
    @Local var showToken = false
    var body: some View {
        let link = studio.controlLink
        let helper = Bundle.main.bundlePath + "/Contents/MacOS/framecast-mcp"
        let testArg = CollectionStore.profile == "default" ? "" : " --test"
        SettingsGroup(title: "Control link",
                      footer: "Lets you prepare and run shows by chatting with Claude Desktop or Claude Code on your own Claude plan: \"prepare my next stream about…\" and Claude writes the outline and makes the cards inside Framecast. They can also switch and make scenes, show overlays and add markers. They can't record, broadcast or change sound. Only apps on this Mac that have the token can connect; it's kept in a file only you can read. Not needed to go live.") {
            SettingRow(title: "Let Claude or another MCP app control Framecast", detail: link.isRunning ? "On, at \(ControlLink.url)" : (link.problem ?? "Off")) {
                Toggle("", isOn: Binding(get: { settings.s.controlLink == true }, set: { on in
                    settings.s.controlLink = on
                    if on { link.start() } else { link.stop() }
                })).toggleStyle(.switch).labelsHidden()
            }
            if settings.s.controlLink == true {
                if let last = link.lastCall { Text("Last request: \(last)").font(.fc(11)).foregroundStyle(Theme.text3) }
                snippet("Claude Desktop (Settings › Developer › Edit Config)",
                        "{\n  \"mcpServers\": {\n    \"framecast\": { \"command\": \"\(helper)\"\(testArg.isEmpty ? "" : ", \"args\": [\"--test\"]") }\n  }\n}")
                snippet("Claude Code", "claude mcp add framecast -- \"\(helper)\"\(testArg)")
                snippet("Other MCP apps (HTTP)", "\(ControlLink.url)\nAuthorization: Bearer \(showToken ? link.currentToken : String(repeating: "•", count: 16))",
                        copy: "\(ControlLink.url)\nAuthorization: Bearer \(link.currentToken)")
                HStack {
                    Button(showToken ? "Hide Token" : "Show Token") { showToken.toggle() }
                    Button("New Token") { link.renewToken() }.help("Apps set up with the old token by header need the new one; the helper picks it up by itself.")
                }.font(.fc(12))
            }
        }
    }
    func snippet(_ title: String, _ text: String, copy: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.fc(11.5, .semibold)).foregroundStyle(Theme.text2)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy ?? text, forType: .string) }
                    .buttonStyle(.plain).font(.fc(11.5, .semibold)).foregroundStyle(Theme.accent)
            }
            Text(text).font(.fc(11).monospaced()).foregroundStyle(Theme.text).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
        }
    }
}
