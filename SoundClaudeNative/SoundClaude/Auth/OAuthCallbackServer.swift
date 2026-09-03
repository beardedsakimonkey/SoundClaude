import Foundation
import Network

enum OAuthCallbackError: LocalizedError {
    case portInUse
    case timeout
    case cancelled(String)
    case listenerFailed

    var errorDescription: String? {
        switch self {
        case .portInUse:
            return "The sign-in callback port 32148 is in use."
        case .timeout:
            return "SoundCloud sign-in timed out. Try again."
        case let .cancelled(message):
            return message
        case .listenerFailed:
            return "The sign-in callback could not be received."
        }
    }
}

/// A short-lived loopback-only HTTP listener for the registered OAuth callback.
final class OAuthCallbackServer: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(
        label: "com.tim.soundclaude.native.oauth-callback"
    )
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var resultContinuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var timeoutTimer: DispatchSourceTimer?
    private var isReady = false
    private var isFinished = false

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredInterfaceType = .loopback
                    let listener = try NWListener(
                        using: parameters,
                        on: NWEndpoint.Port(rawValue: 32_148)!
                    )
                    self.listener = listener
                    self.readyContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.receiveRequest(connection: connection, data: Data())
                    }
                    listener.start(queue: queue)
                } catch {
                    continuation.resume(throwing: OAuthCallbackError.portInUse)
                }
            }
        }
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard isReady, !isFinished else {
                    if let pendingResult {
                        self.pendingResult = nil
                        continuation.resume(with: pendingResult)
                    } else {
                        continuation.resume(throwing: OAuthCallbackError.listenerFailed)
                    }
                    return
                }
                resultContinuation = continuation
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 300)
                timer.setEventHandler { [weak self] in
                    self?.finish(.failure(OAuthCallbackError.timeout))
                }
                timer.resume()
                timeoutTimer = timer
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            if resultContinuation != nil {
                finish(.failure(OAuthCallbackError.cancelled("Sign-in was cancelled.")))
            } else {
                listener?.cancel()
                listener = nil
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isReady = true
            readyContinuation?.resume()
            readyContinuation = nil
        case .failed:
            readyContinuation?.resume(throwing: OAuthCallbackError.portInUse)
            readyContinuation = nil
            finish(.failure(OAuthCallbackError.listenerFailed))
        case .cancelled:
            if !isFinished, let resultContinuation {
                self.resultContinuation = nil
                resultContinuation.resume(
                    throwing: OAuthCallbackError.listenerFailed
                )
            }
        default:
            break
        }
    }

    private func receiveRequest(connection: NWConnection, data: Data) {
        connection.start(queue: queue)
        receiveMore(connection: connection, data: data)
    }

    private func receiveMore(connection: NWConnection, data: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16_384
        ) { [weak self] received, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = data
            if let received {
                requestData.append(received)
            }
            if requestData.count > 32_768 {
                self.respond(
                    connection: connection,
                    status: "413 Payload Too Large",
                    title: "Invalid request",
                    message: "Return to SoundClaude and try again."
                )
                return
            }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handleRequest(connection: connection, data: requestData)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveMore(connection: connection, data: requestData)
            }
        }
    }

    private func handleRequest(connection: NWConnection, data: Data) {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first,
              requestLine.hasPrefix("GET "),
              let target = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(
                string: "http://127.0.0.1:32148\(target)"
              ),
              components.path == "/callback" else {
            respond(
                connection: connection,
                status: "404 Not Found",
                title: "Not found",
                message: "This address is only used for SoundCloud sign-in."
            )
            return
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        guard values["state"] == expectedState else {
            respond(
                connection: connection,
                status: "400 Bad Request",
                title: "Invalid authorization response",
                message: "This response did not match the active sign-in request."
            )
            return
        }
        if let oauthError = values["error"] {
            let message = values["error_description"] ?? oauthError
            respond(
                connection: connection,
                status: "400 Bad Request",
                title: "Authorization cancelled",
                message: "Return to SoundClaude to try again."
            )
            finish(.failure(OAuthCallbackError.cancelled(message)))
            return
        }
        guard let code = values["code"], !code.isEmpty else {
            respond(
                connection: connection,
                status: "400 Bad Request",
                title: "Invalid authorization response",
                message: "SoundCloud did not provide an authorization code."
            )
            return
        }
        respond(
            connection: connection,
            status: "200 OK",
            title: "Authorization received",
            message: "Return to SoundClaude to finish sign-in."
        )
        finish(.success(code))
    }

    private func respond(
        connection: NWConnection,
        status: String,
        title: String,
        message: String
    ) {
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,sans-serif;max-width:520px;margin:80px auto">
        <h1 style="color:#f50">\(title)</h1><p>\(message)</p></body></html>
        """
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func finish(_ result: Result<String, Error>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTimer?.cancel()
        timeoutTimer = nil
        listener?.cancel()
        listener = nil
        guard let resultContinuation else {
            pendingResult = result
            return
        }
        self.resultContinuation = nil
        resultContinuation.resume(with: result)
    }
}
