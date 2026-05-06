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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        connectionState = .disconnected
        messages = []
    }


    var unreadCount: Int {
        messages.filter { !$0.isRead }.count
    }

    mutating func insertMessage(_ message: NtfyMessage) {
        guard !messages.contains(message) else { return }
        let insertAt = messages.firstIndex { $0.time < message.time } ?? messages.count
        messages.insert(message, at: insertAt)
    }

    mutating func markRead(_ message: NtfyMessage) {
        guard let id = messages.firstIndex(where: { $0.id == message.id }), !messages[id].isRead else { return }
        messages[id].isRead = true
    }
}
