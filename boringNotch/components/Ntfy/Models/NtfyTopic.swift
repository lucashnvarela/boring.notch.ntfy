//
//  NtfyTopic.swift
//  boringNotch
//
//  Created by Lucas Varela on 28/04/2026.
//

import Foundation

struct NtfyTopic: Identifiable, Codable, Equatable {
    let name: String
    let displayName: String?
    var connectionState: WebSocketClient.ConnectionState
    var messages: [NtfyMessage]

    enum CodingKeys: String, CodingKey {
        case name = "topic"
        case displayName = "display_name"
    }

    var id: String { name }
    var isConnected: Bool { connectionState == .connected }
    var isDisabled: Bool { connectionState == .disabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        connectionState = .disabled
        messages = []
    }

    var unreadCount: Int {
        messages.filter({ !$0.isRead }).count
    }

    mutating func insertMessage(_ message: NtfyMessage) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }

        let insertAt = messages.firstIndex(where: { $0.time < message.time }) ?? messages.count
        messages.insert(message, at: insertAt)

        if messages.count > 50 { messages.removeLast() }
    }

    mutating func markRead(_ message: NtfyMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }), !messages[idx].isRead else { return }
        messages[idx].isRead = true
    }
}
