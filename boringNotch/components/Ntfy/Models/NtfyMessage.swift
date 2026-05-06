//
//  NtfyMessage.swift
//  boringNotch
//
//  Created by Lucas Varela on 26/04/2026.
//

import Foundation
import SwiftUI

enum NtfyMessagePriority: Int, CaseIterable, Identifiable, Codable {
    case small = 1
    case low = 2
    case medium = 3
    case high = 4
    case urgent = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .small: return "small"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .urgent: return "urgent"
        }
    }

    var color: Color {
        switch self {
        case .small, .low:
            return .gray
        case .medium:
            return .blue
        case .high:
            return .orange
        case .urgent:
            return .red
        }
    }
}

enum NtfyMessageEvent: String, Codable {
    case message
    case message_delete
    case message_clear
    case poll_request
    case keepalive
    case open
}

struct NtfyMessage: Identifiable, Codable, Equatable {
    let id: String
    let sequenceID: String?
    let topic: String
    let title: String
    let body: String
    let time: Date
    let priority: NtfyMessagePriority
    let event: NtfyMessageEvent
    var isRead: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, topic, title, time, priority, event
        case sequenceID = "sequence_id"
        case body = "message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sequenceID = try c.decodeIfPresent(String.self, forKey: .sequenceID)
        topic = try c.decode(String.self, forKey: .topic)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? topic
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        time = Date(timeIntervalSince1970: try c.decode(TimeInterval.self, forKey: .time))
        priority = try c.decodeIfPresent(NtfyMessagePriority.self, forKey: .priority) ?? .low
        event = try c.decode(NtfyMessageEvent.self, forKey: .event)
    }
}
