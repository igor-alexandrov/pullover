import Foundation
import Network
import os

private let log = Logger(subsystem: "Pullover", category: "mcp")

public let mcpPath = "/mcp"

public func mcpURL(port: Int) -> String {
    "http://127.0.0.1:\(port)\(mcpPath)"
}

public struct MCPServerStatus: Sendable, Equatable {
    public var listening: Bool
    /// The bound port, which is what was asked for unless that was 0.
    public var port: Int?
    /// Why the server is not listening although it was started, or nil.
    public var error: String?

    public static let stopped = MCPServerStatus(listening: false, port: nil, error: nil)
}

/// DNS rebinding: a page on the open web can point a hostname at 127.0.0.1 and
/// have the browser send requests here. Such requests arrive with that
/// hostname in `Host` and the page's origin in `Origin`; a local client sends
/// a loopback `Host` and no `Origin` at all.
public func refusal(for headers: [String: String], port: Int) -> String? {
    let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
    // Both fields are case-insensitive, and the allowlist is fixed, so folding
    // case lets nothing new through.
    guard let host = headers["host"]?.lowercased(), hosts.contains(host) else {
        return "Host \(headers["host"] ?? "(missing)") is not this machine"
    }
    if let origin = headers["origin"], !hosts.contains(where: { origin.lowercased() == "http://\($0)" }) {
        return "Origin \(origin) is not this machine"
    }
    return nil
}

func rpcError(_ message: String, code: Int = -32000, id: JSONValue = .null) -> JSONValue {
    ["jsonrpc": "2.0", "error": ["code": .number(Double(code)), "message": .string(message)], "id": id]
}

/// Serves MCP over Streamable HTTP on the loopback interface. Stateless: every
/// POST is a complete JSON-RPC exchange, answered as plain JSON, and nothing is
/// remembered between requests.
@MainActor
public final class MCPServer {
    public typealias Handler = @Sendable (JSONValue) async -> JSONValue?

    private let handleMessage: Handler
    private let idleTimeout: TimeInterval
    private let queue = DispatchQueue(label: "Pullover.mcp")
    private var listener: NWListener?
    /// The `start` waiting for its listener to settle, which `stop` must release.
    private var pendingStart: ResumeOnce?
    /// Finishes once the last listener `stop` cancelled has let go of its port.
    private var closing: Task<Void, Never>?
    /// Bumped by every `start` and `stop`, so a start that waited can tell it was overtaken.
    private var generation = 0
    public private(set) var status = MCPServerStatus.stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    /// Called on every change of `status`, including a listener failing long after it started.
    public var onStatusChange: ((MCPServerStatus) -> Void)?

    /// `handleMessage` answers one JSON-RPC message, or returns nil for a
    /// notification. A connection that has not sent a whole request within
    /// `idleTimeout` seconds is closed.
    public init(idleTimeout: TimeInterval = 30, handleMessage: @escaping Handler) {
        self.idleTimeout = idleTimeout
        self.handleMessage = handleMessage
    }

    /// Returns once the outcome is known. A port that cannot be bound is
    /// reported by `status`, not thrown.
    public func start(port: Int) async {
        stop()
        let mine = generation
        // Binding while the old listener still holds the port would report a
        // conflict against a listener of this server's own.
        await closing?.value
        guard generation == mine else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            status = MCPServerStatus(listening: false, port: nil, error: error.localizedDescription)
            return
        }
        self.listener = listener

        let handler = handleMessage
        let queue = self.queue
        let idleTimeout = self.idleTimeout
        listener.newConnectionHandler = { connection in
            let bound = Int(listener.port?.rawValue ?? UInt16(clamping: port))
            MCPConnection(connection: connection, port: bound, handler: handler).start(on: queue, idleTimeout: idleTimeout)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeOnce(continuation)
            pendingStart = resumed
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else {
                        resumed.resume()
                        return
                    }
                    switch state {
                    case .ready:
                        self.status = MCPServerStatus(listening: true, port: listener.port.map { Int($0.rawValue) }, error: nil)
                    case let .failed(error), let .waiting(error):
                        self.status = MCPServerStatus(listening: false, port: nil, error: Self.describe(error, port: port))
                        listener.cancel()
                        self.listener = nil
                    case .cancelled:
                        if self.status.listening { self.status = .stopped }
                    default:
                        return
                    }
                    resumed.resume()
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        generation += 1
        if let listener {
            let (cancelled, signal) = AsyncStream<Void>.makeStream()
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { signal.finish() }
            }
            listener.cancel()
            closing = Task { for await _ in cancelled {} }
        }
        listener = nil
        status = .stopped
        // With its state handler gone, nothing else would ever let a pending start return.
        pendingStart?.resume()
        pendingStart = nil
    }

    private static func describe(_ error: NWError, port: Int) -> String {
        if case let .posix(code) = error, code == .EADDRINUSE {
            return "Port \(port) is in use — quit whatever holds it, then turn this off and on."
        }
        return error.localizedDescription
    }

    /// Everything between the socket and the JSON-RPC handler: the path, the
    /// method, the DNS-rebinding check, and JSON parsing. Pure, so it can be
    /// tested without a socket.
    public static func respond(to request: HTTPRequest, port: Int, handler: Handler) async -> HTTPResponse {
        if let refusal = refusal(for: request.headers, port: port) {
            return .json(403, rpcError(refusal))
        }
        guard request.path == mcpPath else {
            return .json(404, rpcError("Nothing here; the MCP endpoint is \(mcpPath)"))
        }
        guard request.method == "POST" else {
            return .json(405, rpcError("Only POST is served; this server holds no sessions"), headers: ["Allow": "POST"])
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return .json(400, rpcError("Parse error: the body is not JSON", code: -32700))
        }

        if case let .array(batch) = message {
            var replies: [JSONValue] = []
            for each in batch {
                if let reply = await handler(each) { replies.append(reply) }
            }
            return replies.isEmpty ? HTTPResponse(status: 202) : .json(200, .array(replies))
        }
        guard let reply = await handler(message) else { return HTTPResponse(status: 202) }
        return .json(200, reply)
    }
}

/// Resumes a continuation at most once, whichever listener state gets there first.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// One accepted socket: reads a request, answers it, closes.
private final class MCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let port: Int
    private let handler: MCPServer.Handler
    private var buffer = Data()
    /// Touched only on the connection's queue.
    private var received = false

    init(connection: NWConnection, port: Int, handler: @escaping MCPServer.Handler) {
        self.connection = connection
        self.port = port
        self.handler = handler
    }

    func start(on queue: DispatchQueue, idleTimeout: TimeInterval) {
        connection.start(queue: queue)
        // A client that connects and never finishes a request would otherwise
        // hold its socket, and this object, forever.
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak self] in
            guard let self, !received else { return }
            connection.cancel()
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            let parsed = parseHTTPRequest(buffer)
            if parsed != .incomplete { received = true }
            switch parsed {
            case let .complete(request):
                let port = self.port
                let handler = self.handler
                Task {
                    let response = await MCPServer.respond(to: request, port: port, handler: handler)
                    self.send(response)
                }
            case let .invalid(reason):
                send(.json(400, rpcError(reason)))
            case .tooLarge:
                send(.json(413, rpcError("Request too large")))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [connection] error in
            if let error { log.error("failed to answer: \(error.localizedDescription)") }
            connection.cancel()
        })
    }
}
