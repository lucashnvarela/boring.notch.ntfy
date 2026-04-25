import Combine
import Foundation

@MainActor
final class WebSocketClient {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var intentionalDisconnect = false

    private(set) var state: ConnectionState = .disconnected
    var onStateChange: ((ConnectionState) -> Void)?
    var onMessage: ((Result<String, Error>) -> Void)?

    init() {
        self.session = URLSession(configuration: URLSessionConfiguration.default)
    }

    func connect(url: URL, headers: [String: String]) {
        disconnect()

        intentionalDisconnect = false

        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        setState(.connecting)

        let webSocketTask = session.webSocketTask(with: request)
        task = webSocketTask

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: webSocketTask)
        }

        webSocketTask.resume()
    }

    func disconnect() {
        intentionalDisconnect = true

        receiveTask?.cancel()
        receiveTask = nil

        task?.cancel(with: .normalClosure, reason: nil)
        task = nil

        setState(.disconnected)
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        var handshakeConfirmed = false

        while !Task.isCancelled {
            do {
                let message = try await task.receive()

                if !handshakeConfirmed {
                    handshakeConfirmed = true
                    setState(.connected)
                }

                switch message {
                case let .string(text):
                    notifyMessage(.success(text))
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        notifyMessage(.success(text))
                    }
                @unknown default:
                    break
                }
            } catch {
                guard !intentionalDisconnect, !Task.isCancelled else { return }
                NSLog("WebSocket error: \(error.localizedDescription)")
                setState(.failed(error.localizedDescription))
                return
            }
        }
    }

    private func setState(_ newState: ConnectionState) {
        state = newState
        onStateChange?(newState)
    }

    private func notifyMessage(_ result: Result<String, Error>) {
        onMessage?(result)
    }
}
