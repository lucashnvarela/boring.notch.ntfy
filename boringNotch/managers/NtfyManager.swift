//
//  NtfyManager.swift
//  boringNotch
//
//  Created by Lucas Varela on 26/04/2026.
//

import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
final class NtfyManager: ObservableObject {
    static let shared = NtfyManager()

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published private(set) var notifications: [NtfyNotificationModel] = [] {
        didSet {
            NtfyStateViewModel.shared.setNotifications(notifications)
        }
    }
    @Published private(set) var connectionStateByTopic: [String: WebSocketClient.ConnectionState] = [:]
    @Published private(set) var latestNotification: NtfyNotificationModel?

    private var clientsByTopic: [String: WebSocketClient] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        bindDefaults()
        reconnectAll()
    }

    private func bindDefaults() {
        Defaults.publisher(.ntfyEnabled)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconnectAll() }
            .store(in: &cancellables)

        Defaults.publisher(.ntfyTopics)
            .sink { [weak self] _ in
                guard let topic = Defaults[.ntfyTopics].last else { return }
                self?.startTopic(topic)
            }
            .store(in: &cancellables)
    }

    func addTopic(_ topic: String) {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !Defaults[.ntfyTopics].contains(t) else { return }
        Defaults[.ntfyTopics].append(t)
    }

    func reconnectAll() {
        stopAll()
        guard Defaults[.ntfyEnabled] else {
            return
        }
        let topics = Defaults[.ntfyTopics].filter { !$0.isEmpty }
        for topic in topics {
            startTopic(topic)
        }
    }

    private func stopAll() {
        for (_, client) in clientsByTopic {
            client.disconnect()
        }
        clientsByTopic.removeAll()
        connectionStateByTopic.removeAll()
    }

    private func startTopic(_ topic: String) {
        guard let url = makeWebSocketURL(serverURLString: Defaults[.ntfyServerURL], topic: topic) else {
            connectionStateByTopic[topic] = .failed("Invalid server URL")
            return
        }

        let headers = makeAuthHeaders(auth: Defaults[.ntfyAuth])
        let client = WebSocketClient()

        client.onStateChange = { [weak self] state in
            self?.connectionStateByTopic[topic] = state
        }

        client.onMessage = { [weak self] result in
            switch result {
            case let .success(text):
                self?.handleIncomingText(text, fallbackTopic: topic)
            case .failure:
                break
            }
        }

        clientsByTopic[topic] = client
        client.connect(url: url, headers: headers)
    }

    private func handleIncomingText(_ text: String, fallbackTopic: String) {
        guard let data = text.data(using: .utf8) else { return }
        let decoder = JSONDecoder()

        guard let wire = try? decoder.decode(NtfyWireMessage.self, from: data),
              let notification = wire.toNotification(fallbackTopic: fallbackTopic)
        else { return }

        notifications.insert(notification, at: 0)
        latestNotification = notification

        if Defaults[.ntfyEnableSneakPeek] {
            coordinator.toggleSneakPeek(status: true, type: .ntfy, duration: 3)
        }
    }

    private func makeAuthHeaders(auth: NtfyAuthConfig) -> [String: String] {
        switch auth {
        case .none:
            return [:]
        case let .basic(username, password):
            let b64 = Data("\(username):\(password)".utf8).base64EncodedString()
            return ["Authorization": "Basic \(b64)"]
        case let .token(token):
            return ["Authorization": "Bearer \(token)"]
        }
    }

    private func makeLoadSubscriptionsRequest() -> URLRequest? {
        guard var components = URLComponents(string: Defaults[.ntfyServerURL]) else { return nil }
        if components.scheme != "http" { components.scheme = "https" }
        components.path = "/v1/account"

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        switch Defaults[.ntfyAuthentication] {
        case .none:
            break
        default:
            makeAuthHeaders(auth: Defaults[.ntfyAuthentication]).forEach {
                request.setValue($1, forHTTPHeaderField: $0)
            }
        }

        return request
    }

    private func makeSyncMessagesRequest(for topic: String, since: String) -> URLRequest? {
        guard var components = URLComponents(string: Defaults[.ntfyServerURL]) else { return nil }
        if components.scheme != "http" { components.scheme = "https" }
        components.path = "/\(topic)/json"
        components.queryItems = [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since)
        ]

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        switch Defaults[.ntfyAuthentication] {
        case .none:
            break
        default:
            makeAuthHeaders(auth: Defaults[.ntfyAuthentication]).forEach {
                request.setValue($1, forHTTPHeaderField: $0)
            }
        }

        return request
    }

    private func makeWebSocketRequest(for topic: String) -> URLRequest? {
        guard var components = URLComponents(string: Defaults[.ntfyServerURL]) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http":  components.scheme = "ws"
        case "ws", "wss": break
        default:      components.scheme = "wss"
        }
        components.path = "/\(topic)/ws"

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)

        switch Defaults[.ntfyAuthentication] {
        case .none:
            break
        default:
            makeAuthHeaders(auth: Defaults[.ntfyAuthentication]).forEach {
                request.setValue($1, forHTTPHeaderField: $0)
            }
        }

        return request
    }
}
