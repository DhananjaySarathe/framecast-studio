import Foundation
import Observation
import FramecastEngine

enum ChatPlatform: String, Codable, CaseIterable { case youtube, twitch, x, instagram, guest }
enum ChatRole: String, Codable { case none, mod, member, you }
enum ChatKindFilter: String, CaseIterable { case all, paid, messages }

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    var platform: ChatPlatform
    var user: String
    var role: ChatRole = .none
    var text: String
    var date = Date()
    var paidAmount: String? = nil     // Super Chat / Bits label
    var remoteID: String? = nil
}

/// Live chat from every connected platform plus backstage chat with guests, in one place.
@Observable
final class ChatHub {
    unowned let studio: Studio
    var messages: [ChatMessage] = []
    var backstage: [ChatMessage] = []
    var hiddenPlatforms: Set<ChatPlatform> = []
    var kind: ChatKindFilter = .all
    var draft = ""
    var backstageDraft = ""
    var pinned: ChatMessage?
    var connectors: [ChatConnector] = []
    var status: String?

    init(studio: Studio) { self.studio = studio }

    var visible: [ChatMessage] {
        messages.filter { !hiddenPlatforms.contains($0.platform) && (kind != .paid || $0.paidAmount != nil) }
    }

    func receive(_ m: ChatMessage) {
        guard !messages.contains(where: { $0.remoteID != nil && $0.remoteID == m.remoteID }) else { return }
        messages.append(m)
        if messages.count > 2_000 { messages.removeFirst(messages.count - 2_000) }
    }

    /// Show a message on stream (click again to take it off).
    func toggleOnScreen(_ m: ChatMessage) {
        if studio.chatOnScreen == m.id {
            studio.engine.showChat(nil); studio.chatOnScreen = nil
        } else {
            studio.engine.showChat(ChatOverlay(author: m.user, text: m.text, platform: m.platform.rawValue))
            studio.chatOnScreen = m.id
        }
    }

    /// Sends to every connected platform that supports writing. Local echo either way.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        var sent = false
        for c in connectors where c.canSend { c.send(text); sent = true }
        if !sent { status = "Connect YouTube or Twitch in Destinations to reply to viewers. For now your message stays here." }
        messages.append(ChatMessage(platform: .guest, user: "You", role: .you, text: text))
    }


    func sendBackstage() {
        let text = backstageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        backstageDraft = ""
        backstage.append(ChatMessage(platform: .guest, user: "You", role: .you, text: text))
        studio.guests.sendChat(text)
    }
}

/// A source of live chat (YouTube, Twitch). Implementations live in ChatConnectors.swift.
protocol ChatConnector: AnyObject {
    var platform: ChatPlatform { get }
    var canSend: Bool { get }
    func start()
    func stop()
    func send(_ text: String)
}
