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

private struct NtfyAccount: Decodable {
    let username: String
    let role: String
    let subscriptions: [NtfyTopic]?
}

@MainActor
final class NtfyManager: ObservableObject {
    enum AuthenticationState {
        case disconnected
        case unauthorized
        case authenticated
        case nosubscriptions
        case failed(String)
    }

    static let shared = NtfyManager()

    @Published private(set) var authState: AuthenticationState = .disconnected

    private let tvm = NtfyStateViewModel.shared
    private var wsSessions: [String: WebSocketClient] = [:]
    private var syncMessagesTasks: [String: Task<Void, Never>] = [:]
    private var startupPipelineTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        bindDefaults()
        setupSystemStateObservers()
    }

    private func bindDefaults() {
        Defaults.publisher(.boringNtfy)
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    state.newValue ? self?.startSession() : self?.terminateSession()
                }
            }
            .store(in: &cancellables)
    }

    private func setupSystemStateObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startSession()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminateSession()
            }
        }
    }

    private func terminateSession() {
        startupPipelineTask?.cancel()
        startupPipelineTask = nil
        authState = .disconnected
        unsubscribeAll()
    }

    private func startSession() {
        guard Defaults[.boringNtfy] else { return }
        startupPipelineTask?.cancel()
        startupPipelineTask = Task { @MainActor [weak self] in
            await self?.loadSubscriptions()
        }
    }

    func restartSession() {
        terminateSession()
        startSession()
    }

    private func loadSubscriptions() async {
        guard let request = makeLoadSubscriptionsRequest() else { return }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }

            switch httpResponse.statusCode {
            case 200:
                authState = .authenticated
                let account = try JSONDecoder().decode(NtfyAccount.self, from: data)
                guard let topics = account.subscriptions else {
                    authState = .nosubscriptions
                    return
                }
                topics.forEach { subscribe(to: $0) }
            case 401, 403:
                authState = .unauthorized
                return
            default:
                return
            }
        } catch {
            authState = .failed("Could not connect to the server")
            NSLog("\(error)")
        }
    }

    private func unsubscribeAll() {
        for topic in tvm.topics {
            disconnect(from: topic.name)
            tvm.removeTopic(topic)
        }
    }

    private func subscribe(to topic: NtfyTopic) {
        tvm.addTopic(topic)
        connect(to: topic.name)
    }

    func toggleConnection(_ isOn: Bool, for topic: String) {
        if isOn { connect(to: topic) }
        else { disconnect(from: topic) }
    }

    private func disconnect(from topic: String) {
        wsSessions[topic]?.disconnect()
        wsSessions.removeValue(forKey: topic)
        syncMessagesTasks[topic]?.cancel()
        syncMessagesTasks.removeValue(forKey: topic)
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
