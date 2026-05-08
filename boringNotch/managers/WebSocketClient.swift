//
//  WebSocketClient.swift
//  boringNotch
//
//  Created by Lucas Varela on 26/04/2026.
//

import Foundation

final class WebSocketClient: NSObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private var session: URLSession!
    private var socketTask: URLSessionWebSocketTask?
    private var listenerTask: Task<Void, Never>?

    var onStateChange: ((ConnectionState) -> Void)?
    var onMessage: ((Result<String, Error>) -> Void)?

    override init() {
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func connect(with request: URLRequest) {
        listenerTask?.cancel()
        listenerTask = nil
        
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = session.webSocketTask(with: request)
        
        updateState(.connecting)
        socketTask?.resume()
    }

    func disconnect() {
        listenerTask?.cancel()
        listenerTask = nil
        
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
    }

    private func receiveMessages() async {
        guard let task = socketTask else { return }
        
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    forwardMessage(.success(text))
                case let .data(data):
                    guard let text = String(data: data, encoding: .utf8) else { return }
                    forwardMessage(.success(text))
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                
                updateState(.failed("\(error)"))
                NSLog("\(error)")
                
                task.cancel(with: .abnormalClosure, reason: nil)
            }
        }
    }

    private func updateState(_ newState: ConnectionState) {
        let callback = onStateChange
        DispatchQueue.main.async { callback?(newState) }
    }

    private func forwardMessage(_ result: Result<String, Error>) {
        let callback = onMessage
        DispatchQueue.main.async { callback?(result) }
    }
}

extension WebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        updateState(.connected)
        listenerTask = Task { [weak self] in
            await self?.receiveMessages()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        listenerTask?.cancel()
        listenerTask = nil
        updateState(.disconnected)
    }
}
