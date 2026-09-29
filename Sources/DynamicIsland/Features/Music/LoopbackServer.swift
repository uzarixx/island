import Foundation
import Network

/// Minimal HTTP server on 127.0.0.1 that waits for the OAuth redirect.
@MainActor
final class LoopbackServer {
    private let port: UInt16
    private let onCallback: ([String: String]) -> Void
    private var listener: NWListener?

    init(port: UInt16, onCallback: @escaping ([String: String]) -> Void) {
        self.port = port
        self.onCallback = onCallback
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            MainActor.assumeIsolated { self?.respond(to: request, on: connection) }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
        guard target.hasPrefix("/callback"), let components = URLComponents(string: "http://127.0.0.1" + target) else {
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            return
        }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name] = item.value
        }

        let message = params["code"] != nil
            ? L("Spotify подключён. Вкладку можно закрыть.", "Spotify is connected. You can close this tab.")
            : L("Не удалось подключить Spotify. Вкладку можно закрыть.", "Couldn’t connect Spotify. You can close this tab.")
        let body = """
        <!doctype html><html lang="\(AppLanguage.current.code)"><meta charset="utf-8"><title>Island</title>
        <body style="font-family:-apple-system;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0">
        <h2>\(message)</h2></body>
        """
        let bodyData = Data(body.utf8)
        send(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n" + body,
            on: connection
        )
        onCallback(params)
    }

    private func send(_ response: String, on connection: NWConnection) {
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
