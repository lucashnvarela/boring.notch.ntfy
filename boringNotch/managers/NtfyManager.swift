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

    private func connect(to topic: String) {
        guard case .authenticated = authState else { return }
        guard let request = makeWebSocketRequest(for: topic) else {
            tvm.updateConnectionState(.failed("Could not make the WebSocket request"), for: topic)
            return
        }

        let wsClient = WebSocketClient()

        wsClient.onStateChange = { [weak self] newState in
            self?.tvm.updateConnectionState(newState, for: topic)
            if case .connected = newState {
                self?.syncMessagesTasks[topic]?.cancel()
                self?.syncMessagesTasks[topic] = Task { @MainActor [weak self] in
                    await self?.syncMessages(for: topic)
                }
            }
        }

        wsClient.onMessage = { [weak self] result in
            switch result {
            case let .success(text):
                self?.handleResponse(Data(text.utf8))
            case .failure:
                break
            }
        }

        wsSessions[topic] = wsClient
        wsClient.connect(with: request)
    }

    private func syncMessages(for topic: String) async {
        guard case .authenticated = authState else { return }
        let lastestMessageID = tvm.latestMessage(from: topic)?.id
        guard let request = makeSyncMessagesRequest(for: topic, since: lastestMessageID ?? "12h") else { return }

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await text in bytes.lines {
                guard !text.isEmpty else { return }
                handleResponse(Data(text.utf8))
            }
        } catch {
            NSLog("\(error)")
        }
    }

    private func handleResponse(_ data: Data) {
        guard let message = try? JSONDecoder().decode(NtfyMessage.self, from: data) else { return }
        guard message.event == .message else { return }

        tvm.insertMessage(message)

        if Defaults[.ntfyEnableSneakPeek] {
            BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .ntfy, duration: message.priority.rawValue > 3 ? 5 : 3)
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
