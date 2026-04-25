import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
final class NtfyManager: ObservableObject {
    static let shared = NtfyManager()

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published private(set) var notifications: [NtfyNotification] = [] {
        didSet {
            NtfyStateViewModel.shared.setNotifications(notifications)
            NtfyPersistenceService.shared.save(notifications)
        }
    }
    @Published private(set) var connectionStateByTopic: [String: WebSocketClient.ConnectionState] = [:]
    @Published private(set) var latestNotification: NtfyNotification?

    private var clientsByTopic: [String: WebSocketClient] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let loaded = NtfyPersistenceService.shared.load()
        _notifications = Published(initialValue: loaded)
        NtfyStateViewModel.shared.setNotifications(loaded)
        bindDefaults()
        applyCurrentConfiguration()
    }

    private func bindDefaults() {
        let keys: [AnyPublisher<Void, Never>] = [
            Defaults.publisher(.ntfyEnabled).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.ntfyServerURL).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.ntfyTopics).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.ntfyAuth).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableSneakPeek).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.ntfyMaxStoredNotifications).map { _ in () }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(keys)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.applyCurrentConfiguration()
            }
            .store(in: &cancellables)
    }

    private func applyCurrentConfiguration() {
        guard Defaults[.ntfyEnabled] else {
            stopAll()
            return
        }

        let topics = Defaults[.ntfyTopics].filter { !$0.isEmpty }

        let desired = Set(topics)
        let existing = Set(clientsByTopic.keys)

        let toRemove = existing.subtracting(desired)
        let toAdd = desired.subtracting(existing)

        for topic in toRemove {
            clientsByTopic[topic]?.disconnect()
            clientsByTopic[topic] = nil
            connectionStateByTopic[topic] = nil
        }

        for topic in toAdd {
            startTopic(topic)
        }

        for topic in desired {
            reconnectTopic(topic)
        }

        trimIfNeeded()
    }

    func clearNotifications() {
        notifications = []
    }

    private func stopAll() {
        for (_, client) in clientsByTopic {
            client.disconnect()
        }
        clientsByTopic.removeAll()
        connectionStateByTopic.removeAll()
    }

    func reconnectTopic(_ topic: String) {
        clientsByTopic[topic]?.disconnect()
        clientsByTopic[topic] = nil
        startTopic(topic)
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
        trimIfNeeded()

        if Defaults[.ntfyEnableSneakPeek] {
            if Defaults[.ntfySneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .ntfy)
            } else {
                coordinator.toggleExpandingView(status: true, type: .ntfy)
            }
        }
    }

    private func trimIfNeeded() {
        let maxCount = max(0, Defaults[.ntfyMaxStoredNotifications])
        guard maxCount > 0 else { return }
        if notifications.count > maxCount {
            notifications = Array(notifications.prefix(maxCount))
        }
    }

    private func makeAuthHeaders(auth: NtfyAuthConfig) -> [String: String] {
        switch auth {
        case .none:
            return [:]
        case let .basic(username, password):
            let creds = "\(username):\(password)"
            let b64 = Data(creds.utf8).base64EncodedString()
            return ["Authorization": "Basic \(b64)"]
        case let .token(token):
            return ["Authorization": "Bearer \(token)"]
        }
    }

    private func makeWebSocketURL(serverURLString: String, topic: String) -> URL? {
        guard var components = URLComponents(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "ws", "wss":
            break
        default:
            if components.scheme == nil {
                components.scheme = "wss"
            }
        }

        let basePath = (components.path as NSString).standardizingPath
        let normalizedBase = basePath == "/" ? "" : basePath
        let fullPath = "\(normalizedBase)/\(topic)/ws"
        components.path = fullPath
        return components.url
    }
}
