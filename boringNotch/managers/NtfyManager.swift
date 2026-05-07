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
    enum SessionState {
        case disconnected
        case unauthorized
        case authenticated
        case failed(String)
    }

    static let shared = NtfyManager()

    @Published private(set) var authState: SessionState = .disconnected

    private let tvm = NtfyStateViewModel.shared
    private var webSocketConnections: [String: WebSocketClient] = [:]
    private var syncMessagesTasks: [String: Task<Void, Never>] = [:]
    private var sessionInitTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        setupSettingsObserver()
        setupSystemStateObservers()
    }

    private func setupSettingsObserver() {
        Defaults.publisher(.boringNtfy)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    state.newValue ? self?.startSession() : self?.stopSession()
                }
            }
            .store(in: &cancellables)
    }

    private func setupSystemStateObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspendSession()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startSession()
            }
        }
    }

    private func stopSession() {
        sessionInitTask?.cancel()
        sessionInitTask = nil
        authState = .disconnected
        tvm.unsubscribeAll()
    }

    private func suspendSession() {
        sessionInitTask?.cancel()
        sessionInitTask = nil
        authState = .disconnected
        tvm.topics.forEach {
            disconnect(from: $0.name)
        }
    }

    private func startSession() {
        guard Defaults[.boringNtfy] else { return }
        sessionInitTask?.cancel()
        sessionInitTask = Task { @MainActor [weak self] in
            await self?.loadSubscriptions()
            self?.tvm.topics.forEach {
                self?.connect(to: $0.name)
            }
        }
    }

    func restartSession() {
        stopSession()
        startSession()
    }

    private func loadSubscriptions() async {
        guard let request = makeLoadSubscriptionsRequest() else {
            authState = .failed("Could not make the HTTP request")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return }

            switch statusCode {
            case 200:
                authState = .authenticated
                let account = try JSONDecoder().decode(NtfyAccount.self, from: data)
                guard let topics = account.subscriptions else { return }
                topics.forEach { tvm.subscribe(to: $0) }
            case 401, 403:
                authState = .unauthorized
                return
            default:
                authState = .failed("Could not connect to the server")
                return
            }
        } catch {
            guard !Task.isCancelled else { return }
            authState = .failed("Could not connect to the server")
            NSLog("\(error)")
        }
    }

    func toggleConnection(_ isOn: Bool, for topic: String) {
        if isOn { connect(to: topic) }
        else { disconnect(from: topic) }
    }

    private func disconnect(from topic: String) {
        webSocketConnections[topic]?.disconnect()
        webSocketConnections.removeValue(forKey: topic)
    }

    private func connect(to topic: String) {
        guard case .authenticated = authState else { return }
        guard let request = makeWebSocketRequest(for: topic) else {
            tvm.updateConnectionState(.failed("Could not make the WebSocket request"), for: topic)
            return
        }

        let client = WebSocketClient()

        client.onStateChange = { [weak self] newState in
            self?.tvm.updateConnectionState(newState, for: topic)

            switch newState {
            case .connected:
                self?.syncMessagesTasks[topic]?.cancel()
                self?.syncMessagesTasks[topic] = Task { @MainActor [weak self] in
                    await self?.syncMessages(for: topic)
                }
            case .disconnected, .failed:
                self?.syncMessagesTasks[topic]?.cancel()
                self?.syncMessagesTasks.removeValue(forKey: topic)
            case .connecting:
                break
            }
        }

        client.onMessage = { [weak self] result in
            switch result {
            case let .success(text):
                self?.handleResponse(Data(text.utf8))
            case let .failure(error):
                self?.tvm.updateConnectionState(.failed("Could not receive the WebSocket message"), for: topic)
                NSLog("\(error)")
            }
        }

        webSocketConnections[topic] = client
        client.connect(with: request)
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
            guard !Task.isCancelled else { return }
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
