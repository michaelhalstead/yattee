//
//  LocalHLSServer.swift
//  Yattee
//
//  Minimal HTTP/1.1 server that serves an AirPlay session's HLS playlists and proxies
//  media byte ranges from googlevideo (whose URLs are bound to this device's IP).
//

import Foundation
import Network
import Synchronization

final class LocalHLSServer: Sendable {
    enum Resource: Sendable {
        case text(String, contentType: String)
        /// Forwarded to `url`, passing the client's Range header through.
        case proxy(URL, headers: [String: String])
        /// Byte-range passthrough of a file of known `length`: any client Range (or none) is
        /// served by fetching bounded upstream chunks, since googlevideo 403s open-ended ranges.
        case raw(URL, length: Int64, contentType: String, headers: [String: String])
    }

    enum ServerError: Error, LocalizedError, Sendable {
        case noLocalAddress
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLocalAddress: "No Wi-Fi IPv4 address for the AirPlay server"
            case .listenerFailed(let reason): "AirPlay server failed to start: \(reason)"
            }
        }
    }

    /// `http://<wifi-ip>:<port>/<random-token>/`; resources are served only under this path.
    let baseURL: URL

    private let listener: NWListener
    private let resources: Mutex<[String: Resource]>
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])
    private let queue = DispatchQueue(label: "LocalHLSServer")

    private static let upstream: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init(listener: NWListener, baseURL: URL, resources: [String: Resource]) {
        self.listener = listener
        self.baseURL = baseURL
        self.resources = Mutex(resources)
    }

    /// Starts a server for `resources` (keyed by file name, e.g. "master.m3u8").
    /// With `loopback`, binds 127.0.0.1 only (no Wi-Fi needed, no local-network prompt).
    static func start(resources: [String: Resource], loopback: Bool = false) async throws -> LocalHLSServer {
        guard let host = loopback ? "127.0.0.1" : wifiIPv4Address() else { throw ServerError.noLocalAddress }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if loopback { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
        let listener = try NWListener(using: parameters, on: .any)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: ServerError.listenerFailed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let token = UUID().uuidString.lowercased()
        let server = LocalHLSServer(
            listener: listener,
            baseURL: URL(string: "http://\(host):\(port)/\(token)/")!,
            resources: Dictionary(uniqueKeysWithValues: resources.map { ("/\(token)/\($0.key)", $0.value) })
        )
        listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        LoggingService.shared.debug("Local media server listening at \(server.baseURL.absoluteString)", category: .player)
        return server
    }

    func url(for name: String) -> URL { baseURL.appendingPathComponent(name) }

    private static let sharedLoopback = Mutex<Task<LocalHLSServer, Error>?>(nil)

    /// App-lifetime loopback server for MPV, started on first use.
    static func loopback() async throws -> LocalHLSServer {
        let task = sharedLoopback.withLock { task in
            if let task { return task }
            let new = Task { try await start(resources: [:], loopback: true) }
            task = new
            return new
        }
        do { return try await task.value } catch {
            sharedLoopback.withLock { $0 = nil }
            throw error
        }
    }

    /// Serves `resource` under a new random path and returns its URL.
    // ponytail: registrations are never removed (a few hundred bytes per played stream).
    func register(_ resource: Resource) -> URL {
        let name = "raw/\(UUID().uuidString.lowercased())"
        resources.withLock { $0["/\(baseURL.lastPathComponent)/\(name)"] = resource }
        return url(for: name)
    }

    func stop() {
        listener.cancel()
        let open = connections.withLock { conns in
            defer { conns.removeAll() }
            return Array(conns.values)
        }
        open.forEach { $0.cancel() }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0[ObjectIdentifier(connection)] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(connection)) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                Task { await self.respond(to: head, on: connection) }
            } else if error != nil || isComplete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) async {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return await finish(connection, status: "400 Bad Request") }
        let method = String(requestLine[0])
        let path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "")
        var range: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                range = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        LoggingService.shared.debug("Local media server: \(method) \(path) \(range ?? "")", category: .player)

        guard method == "GET" || method == "HEAD" else { return await finish(connection, status: "405 Method Not Allowed") }
        guard let resource = resources.withLock({ $0[path] }) else { return await finish(connection, status: "404 Not Found") }

        switch resource {
        case .text(let text, let contentType):
            let body = Data(text.utf8)
            await finish(
                connection,
                status: "200 OK",
                headers: ["Content-Type": contentType, "Content-Length": "\(body.count)"],
                body: method == "HEAD" ? nil : body
            )

        case .proxy(let url, let extraHeaders):
            var request = URLRequest(url: url)
            request.httpMethod = method
            extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue(Self.upstreamRange(range), forHTTPHeaderField: "Range")
            do {
                let (bytes, response) = try await Self.upstream.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                var headers = ["Accept-Ranges": "bytes"]
                for name in ["Content-Type", "Content-Length", "Content-Range"] {
                    if let value = http.value(forHTTPHeaderField: name) { headers[name] = value }
                }
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
                try await send(Data(statusHead("\(http.statusCode) \(reason)", headers).utf8), on: connection)
                if method == "GET" {
                    var chunk = Data()
                    chunk.reserveCapacity(65_536)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count == 65_536 {
                            try await send(chunk, on: connection)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { try await send(chunk, on: connection) }
                }
                close(connection)
            } catch {
                LoggingService.shared.debug("AirPlay HLS server: proxy \(path) ended: \(error.localizedDescription)", category: .player)
                connection.cancel()
            }

        case .raw(let url, let length, let contentType, let extraHeaders):
            await serveRaw(url, length: length, contentType: contentType, extraHeaders: extraHeaders,
                           method: method, range: range, path: path, on: connection)
        }
    }

    /// Parses `bytes=N-M`, `bytes=N-` or `bytes=-N` against `length`. Nil when unsatisfiable.
    static func byteSpan(_ range: String?, length: Int64) -> ClosedRange<Int64>? {
        guard length > 0 else { return nil }
        guard let range else { return 0...(length - 1) }
        let bounds = range.replacingOccurrences(of: "bytes=", with: "")
            .split(separator: ",").first?
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? []
        guard bounds.count == 2 else { return nil }
        switch (bounds[0], bounds[1]) {
        case let (start?, end):
            guard start < length, start <= (end ?? start) else { return nil }
            return start...min(end ?? length - 1, length - 1)
        case let (nil, suffix?) where suffix > 0:
            return max(0, length - suffix)...(length - 1)
        default:
            return nil
        }
    }

    private func serveRaw(_ url: URL, length: Int64, contentType: String, extraHeaders: [String: String],
                          method: String, range: String?, path: String, on connection: NWConnection) async {
        guard let span = Self.byteSpan(range, length: length) else {
            return await finish(connection, status: "416 Range Not Satisfiable",
                                headers: ["Content-Range": "bytes */\(length)", "Content-Length": "0"])
        }
        var headers = [
            "Accept-Ranges": "bytes",
            "Content-Type": contentType,
            "Content-Length": "\(span.count)",
        ]
        if range != nil { headers["Content-Range"] = "bytes \(span.lowerBound)-\(span.upperBound)/\(length)" }
        let status = range != nil ? "206 Partial Content" : "200 OK"
        guard method == "GET" else { return await finish(connection, status: status, headers: headers) }

        // MPV seeks by closing the socket; notice that so the loop below stops fetching.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { connection.cancel() }
        }

        // First chunk is small so playback and seeks start fast; later ones use the 8 MB cap.
        var offset = span.lowerBound
        var chunkSize: Int64 = 1 << 20
        var sentHead = false
        do {
            while offset <= span.upperBound {
                guard connection.state == .ready else { throw CancellationError() }
                let end = min(offset + chunkSize - 1, span.upperBound)
                var request = URLRequest(url: url)
                extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                let (data, response) = try await Self.upstream.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 206, Int64(data.count) == end - offset + 1 else {
                    LoggingService.shared.warning("Local media server: upstream \(code) (\(data.count) bytes) for \(path) bytes=\(offset)-\(end)", category: .player)
                    if !sentHead { return await finish(connection, status: code == 403 ? "403 Forbidden" : "502 Bad Gateway") }
                    return connection.cancel()
                }
                if !sentHead {
                    try await send(Data(statusHead(status, headers).utf8), on: connection)
                    sentHead = true
                }
                try await send(data, on: connection)
                offset = end + 1
                chunkSize = 8 << 20
            }
            close(connection)
        } catch {
            // Usually MPV closing the connection to seek.
            LoggingService.shared.debug("Local media server: \(path) ended at \(offset): \(error.localizedDescription)", category: .player)
            connection.cancel()
        }
    }

    /// googlevideo answers 403 to open-ended or very large ranges, so cap each request; a client
    /// asking for more gets a shorter 206 (with an accurate Content-Range) and asks again.
    static func upstreamRange(_ range: String?, limit: UInt64 = 8 << 20) -> String {
        let bounds = (range ?? "").replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
        let start = bounds.first.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let requestedEnd = bounds.count > 1 ? UInt64(bounds[1].trimmingCharacters(in: .whitespaces)) : nil
        return "bytes=\(start)-\(min(requestedEnd ?? .max, start + limit - 1))"
    }

    // MARK: - Writing

    private func statusHead(_ status: String, _ headers: [String: String]) -> String {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return head + "Connection: close\r\n\r\n"
    }

    private func finish(_ connection: NWConnection, status: String, headers: [String: String] = ["Content-Length": "0"], body: Data? = nil) async {
        var data = Data(statusHead(status, headers).utf8)
        if let body { data.append(body) }
        try? await send(data, on: connection)
        close(connection)
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func close(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Address

    /// IPv4 address of en0 (Wi-Fi), else of any other active `en*` interface.
    static func wifiIPv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((name, String(cString: host)))
        }
        return (candidates.first { $0.name == "en0" } ?? candidates.first)?.address
    }
}
