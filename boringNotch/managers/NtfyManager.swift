//
//  NtfyManager.swift
//  boringNotch
//
//  Created by Lucas Varela on 26/04/2026.
//

import Combine
import Defaults
import Foundation
import Network
import SwiftUI

private struct NtfyAccount: Decodable {
    let username: String
    let role: String
    let subscriptions: [NtfyTopic]?
}

@MainActor
final class NtfyManager: ObservableObject {
    enum AuthenticationState: Equatable {
        case unauthorized
        case authenticated
        case failed(String)
    }

    static let shared = NtfyManager()

    @Published private(set) var networkStatus: NWPath.Status?
    @Published private(set) var authState: AuthenticationState?

    private let viewModel = NtfyStateViewModel.shared
    private let coordinator = BoringViewCoordinator.shared
    private let workspace = NSWorkspace.shared
    private let networkMonitor = NWPathMonitor()
    private var resumeConnectionsWorkItem: DispatchWorkItem?
    private var sessionAuthTask: Task<Void, Never>?
    private var webSockets: [String: WebSocketClient] = [:]
    private var syncMessagesTasks: [String: Task<Void, Never>] = [:]
    private var messagesQueue: [NtfyMessage] = []
    private let flushSignal = PassthroughSubject<Void, Never>()
    private var flushQueueTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        setupSettingsObserver()
        setupSystemStateObservers()
        setupMessagesQueue()
    }

    private func setupSettingsObserver() {
        Defaults.publisher(.boringNtfy)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    state.newValue ? self?.resumeConnections() : self?.suspendConnections()
                }
            }
            .store(in: &cancellables)
    }

    private func setupSystemStateObservers() {
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspendConnections()
            }
        }

        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.resumeConnections()
            }
        }
        
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.networkStatus = path.status
                
                switch path.status {
                case .satisfied:
                    try? await Task.sleep(for: .seconds(5))
                    self?.resumeConnections()
                default:
                    self?.suspendConnections()
                }
            }
        }
        networkMonitor.start(queue: DispatchQueue.main)
    }
    
    private func setupMessagesQueue() {
        flushSignal
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    guard case nil = self?.flushQueueTask else { return }
                    
                    self?.flushQueueTask = Task { @MainActor [weak self] in
                        defer { self?.flushQueueTask = nil }
                        await self?.flushQueue()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func cancelMessagesQueue() {
        flushQueueTask?.cancel()
        flushQueueTask = nil

        messagesQueue.removeAll()
        viewModel.resetBatch()
    }

    private func flushQueue() async {
        while !Task.isCancelled, !messagesQueue.isEmpty {
            defer { viewModel.resetBatch() }
            
            guard let topic = messagesQueue.first?.topic else { break }
            let batch = messagesQueue.filter { $0.topic == topic }

            viewModel.commitBatch(batch)
            messagesQueue.removeAll { $0.topic == topic }

            if Defaults[.ntfyEnableSneakPeek] { await showSneakPeek() }
        }
    }

    private func cancelAuthSession() {
        sessionAuthTask?.cancel()
        sessionAuthTask = nil
    }

    private func startAuthSession() {
        sessionAuthTask?.cancel()
        sessionAuthTask = Task { @MainActor [weak self] in
            await self?.loadSubscriptions()
        }
    }

    func restartSession() {
        cancelAuthSession()
        suspendConnections()
        cancelMessagesQueue()
        viewModel.unsubscribeAll()
        startAuthSession()
    }

    private func showSneakPeek() async {
        defer { coordinator.toggleSneakPeek(status: false, type: .ntfy) }
        
        for await sneakPeek in coordinator.$sneakPeek.values {
            guard !Task.isCancelled else { return }
            if !sneakPeek.show { break }
        }

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        AudioPlayer().play(fileName: "ding", fileExtension: "mp3")
        coordinator.toggleSneakPeek(status: true, type: .ntfy, duration: 3)
        
        var didSeeNtfySneakPeek = false
        for await sneakPeek in coordinator.$sneakPeek.values {
            guard !Task.isCancelled else { return }
            if !didSeeNtfySneakPeek {
                if sneakPeek.show && sneakPeek.type == .ntfy {
                    didSeeNtfySneakPeek = true
                }
            } else if !sneakPeek.show {
                break
            }
        }
    }
    
    private func loadSubscriptions() async {
        guard case .satisfied = networkStatus else {
            authState = .failed("Could not connect to the server.")
            return
        }
        
        guard let request = makeLoadSubscriptionsRequest() else {
            authState = .failed("Could not make the request.")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard !Task.isCancelled else { return }
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return }

            switch statusCode {
            case 200:
                authState = .authenticated
                let account = try JSONDecoder().decode(NtfyAccount.self, from: data)
                
                guard let topics = account.subscriptions else { return }
                topics.forEach { viewModel.subscribe(to: $0) }
            case 401, 403:
                authState = .unauthorized
            default:
                authState = .failed("Could not connect to the server.")
            }
        } catch {
            guard !Task.isCancelled else { return }
            
            authState = .failed(error.localizedDescription)
            NSLog("managers.NtfyManager.loadSubscriptions: \(error)")
        }
    }
    
    private func suspendConnections() {
        resumeConnectionsWorkItem?.cancel()
        resumeConnectionsWorkItem = nil
        
        viewModel.topics.forEach {
            switch $0.connectionState {
            case .connected, .connecting:
                disconnect(from: $0.id)
            default:
                return
            }
        }
    }
    
    private func resumeConnections() {
        guard Defaults[.boringNtfy] else { return }
        
        resumeConnectionsWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard case .satisfied = self?.networkStatus else { return }
            
            self?.viewModel.topics.forEach {
                switch $0.connectionState {
                case .disconnected, .failed:
                    self?.connect(to: $0.id)
                default:
                    return
                }
            }
        }
        
        resumeConnectionsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
        
    }

    func toggleConnection(_ isOn: Bool, for topic: String) {
        if isOn {
            viewModel.updateConnectionState(.disconnected, for: topic)
            connect(to: topic)
        } else {
            disconnect(from: topic)
            viewModel.updateConnectionState(.disabled, for: topic)
        }
    }

    private func disconnect(from topic: String) {
        webSockets[topic]?.disconnect()
        webSockets.removeValue(forKey: topic)
    }

    private func connect(to topic: String) {
        guard case .satisfied = networkStatus else {
            viewModel.updateConnectionState(.failed("Could not connect to the server."), for: topic)
            return
        }
        
        guard let request = makeWebSocketRequest(for: topic) else {
            viewModel.updateConnectionState(.failed("Could not make the request."), for: topic)
            return
        }

        let client = WebSocketClient()

        client.onStateChange = { [weak self] newState in
            switch newState {
            case .connected:
                self?.syncMessagesTasks[topic]?.cancel()
                self?.syncMessagesTasks[topic] = Task { @MainActor [weak self] in
                    await self?.syncMessages(for: topic)
                }
            case .disconnected, .failed:
                self?.syncMessagesTasks[topic]?.cancel()
                self?.syncMessagesTasks.removeValue(forKey: topic)
                
                let oldState = self?.viewModel.connectionState(from: topic)
                switch oldState {
                case .disabled, .disconnected:
                    return
                default:
                    break
                }
            default:
                break
            }
            
            self?.viewModel.updateConnectionState(newState, for: topic)
        }

        client.onMessage = { [weak self] result in
            switch result {
            case .success(let text):
                self?.handleResponse(Data(text.utf8))
            case .failure(let error):
                self?.viewModel.updateConnectionState(.failed(error.localizedDescription), for: topic)
                NSLog("managers.NtfyManager.connect(to: \(topic)): \(error)")
            }
        }

        webSockets[topic] = client
        client.connect(with: request)
    }

    private func syncMessages(for topic: String) async {
        guard case .satisfied = networkStatus else { return }
        
        let latestMessageID = viewModel.messages(from: topic).first?.id
        guard let request = makeSyncMessagesRequest(for: topic, since: latestMessageID ?? "12h") else { return }

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await text in bytes.lines {
                guard !text.isEmpty else { continue }
                handleResponse(Data(text.utf8))
            }
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("managers.NtfyManager.syncMessages(for: \(topic)): \(error)")
        }
    }

    private func handleResponse(_ data: Data) {
        guard let message = try? JSONDecoder().decode(NtfyMessage.self, from: data) else { return }
        guard message.event == .message else { return }
        
        messagesQueue.append(message)
        flushSignal.send()
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
