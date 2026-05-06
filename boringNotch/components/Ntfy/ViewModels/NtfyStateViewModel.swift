//
//  NtfyStateViewModel.swift
//  boringNotch
//
//  Created by Lucas Varela on 26/04/2026.
//

import Foundation

@MainActor
final class NtfyStateViewModel: ObservableObject {
    static let shared = NtfyStateViewModel()

    @Published private(set) var topics: [NtfyTopic] = []

    private init() {}

    func addTopic(_ topic: NtfyTopic) {
        guard topics.first(where: { $0.name == topic.name }) == nil else { return }
        topics.append(topic)
    }

    func removeTopic(_ topic: NtfyTopic) {
        topics.removeAll { $0.name == topic.name }
    }

    func updateConnectionState(_ newState: WebSocketClient.ConnectionState, for topic: String) {
        guard let id = topics.firstIndex(where: { $0.name == topic }) else { return }
        topics[id].connectionState = newState
    }

    var connectedCount: Int {
        topics.filter { $0.connectionState == .connected }.count
    }

    func insertMessage(_ message: NtfyMessage) {
        guard let id = topics.firstIndex(where: { $0.name == message.topic }) else { return }
        guard topics[id].messages.first(where: { $0.id == message.id }) == nil else { return }
        topics[id].insertMessage(message)
    }

    func markRead(_ message: NtfyMessage) {
        guard let id = topics.firstIndex(where: { $0.name == message.topic }) else { return }
        topics[id].markRead(message)
    }

    var latestMessage: NtfyMessage? {
        topics.flatMap(\.messages).max(by: { $0.time < $1.time })
    }

    func latestMessage(from topic: String) -> NtfyMessage? {
        topics.first(where: { $0.name == topic })?.messages.first
    }

    func messages(from topic: String?) -> [NtfyMessage] {
        guard let topic else { return topics.filter { $0.isConnected }.flatMap(\.messages).sorted { $0.time > $1.time } }
        return topics.first(where: { $0.name == topic })?.messages ?? []
    }

    var unreadCountAll: Int {
        topics.filter { $0.isConnected }.reduce(0) { $0 + $1.unreadCount }
    }
}
