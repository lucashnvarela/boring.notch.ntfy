//
//  WebSocketClient.swift
//  boringNotch
//
//  Created by Lucas Varela on 26/04/2026.
//

import Foundation

final class WebSocketClient {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private let session: URLSession
    private var socketTask: Task<Void, Never>?
    private var connectionState: ConnectionState?

    var onStateChange: ((ConnectionState) -> Void)?
    var onMessage: ((Result<String, Error>) -> Void)?

    init() {
        self.session = URLSession(configuration: .default)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func connect(with request: URLRequest) {
        socketTask?.cancel()
        updateState(.connecting)
        socketTask = Task { [weak self] in
            await self?.startConnection(with: request)
        }
    }

    func disconnect() {
        socketTask?.cancel()
        socketTask = nil
        updateState(.disconnected)
    }

    private func startConnection(with request: URLRequest) async {
        let webSocketTask = session.webSocketTask(with: request)

        await withTaskCancellationHandler {
            webSocketTask.resume()

            while !Task.isCancelled {
                do {
                    let message = try await webSocketTask.receive()

                    updateState(.connected)

                    switch message {
                    case let .string(text):
                        forwardMessage(.success(text))
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) {
                            forwardMessage(.success(text))
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    
                    updateState(.failed("\(error)"))
                    NSLog("\(error)")

                    webSocketTask.cancel(with: .abnormalClosure, reason: nil)
                    return
                }
            }
        } onCancel: {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func updateState(_ newState: ConnectionState) {
        connectionState = newState
        let callback = onStateChange
        DispatchQueue.main.async { callback?(newState) }
    }

    private func forwardMessage(_ result: Result<String, Error>) {
        let callback = onMessage
        DispatchQueue.main.async { callback?(result) }
    }
}
