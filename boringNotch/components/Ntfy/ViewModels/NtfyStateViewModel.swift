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
    
    private var messagesBatch: [NtfyMessage]?

    private init() {}

    func subscribe(to topic: NtfyTopic) {
        guard !topics.contains(where: { $0.id == topic.id }) else { return }
        topics.append(topic)
    }

    func unsubscribeAll() {
        topics.removeAll()
    }

    func updateConnectionState(_ newState: WebSocketClient.ConnectionState, for topic: String) {
        guard let idx = topics.firstIndex(where: { $0.id == topic }) else { return }
        topics[idx].connectionState = newState
    }
    
    func connectionState(from topic: String) -> WebSocketClient.ConnectionState? {
        guard let idx = topics.firstIndex(where: { $0.id == topic }) else { return nil }
        return topics[idx].connectionState
    }

    var connectedCount: Int {
        topics.filter({ $0.connectionState == .connected }).count
    }

    func commitBatch(_ messages: [NtfyMessage]) {
        messagesBatch = messages
        for message in messages {
            guard let idx = topics.firstIndex(where: { $0.id == message.topic }) else { continue }
            topics[idx].insertMessage(message)
        }
    }
    
    func resetBatch() {
        messagesBatch = nil
    }
    
    var sneakPeekContent: (label: String, priority: NtfyMessagePriority)? {
        guard let messages = messagesBatch, !messages.isEmpty else { return nil }
        
        guard let priority = messages.map(\.priority).max(by: { $0.rawValue < $1.rawValue }) else { return nil }
        
        guard let topic = topics.first(where: { $0.id == messages.first?.topic }) else { return nil }
        let label = "New \(messages.count > 1 ? "messages" : "message") on \(topic.displayName ?? topic.name)"
        
        return (label, priority)
    }

    func markRead(_ message: NtfyMessage) {
        guard let idx = topics.firstIndex(where: { $0.id == message.topic }) else { return }
        topics[idx].markRead(message)
    }

    var latestMessage: NtfyMessage? {
        topics.flatMap(\.messages).max(by: { $0.time < $1.time })
    }

    func messages(from topic: String?) -> [NtfyMessage] {
        guard let topic else { return topics.filter({ $0.connectionState == .connected }).flatMap(\.messages).sorted(by: { $0.time > $1.time }) }
        return topics.first(where: { $0.id == topic })?.messages ?? []
    }

    var unreadCountAll: Int {
        topics.filter({ $0.connectionState == .connected }).reduce(0) { $0 + $1.unreadCount }
    }
}
