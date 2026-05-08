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

    func subscribe(to topic: NtfyTopic) {
        guard !topics.contains(where: { $0.name == topic.name }) else { return }
        topics.append(topic)
    }

    func unsubscribeAll() {
        topics.removeAll()
    }

    func updateConnectionState(_ newState: WebSocketClient.ConnectionState, for topic: String) {
        guard let id = topics.firstIndex(where: { $0.name == topic }) else { return }
        topics[id].connectionState = newState
    }

    var connectedCount: Int {
        topics.filter { $0.connectionState == .connected }.count
    }

    func insertMessage(_ message: NtfyMessage) {
        guard let idx = topics.firstIndex(where: { $0.name == message.topic }) else { return }
        topics[idx].insertMessage(message)
    }

    func markRead(_ message: NtfyMessage) {
        guard let idx = topics.firstIndex(where: { $0.name == message.topic }) else { return }
        topics[idx].markRead(message)
    }

    var latestMessage: NtfyMessage? {
        topics.flatMap(\.messages).max(by: { $0.time < $1.time })
    }

    func messages(from topic: String?) -> [NtfyMessage] {
        guard let topic else { return topics.filter { $0.isConnected }.flatMap(\.messages).sorted { $0.time > $1.time } }
        return topics.first(where: { $0.name == topic })?.messages ?? []
    }

    var unreadCountAll: Int {
        topics.filter { $0.isConnected }.reduce(0) { $0 + $1.unreadCount }
    }
}
