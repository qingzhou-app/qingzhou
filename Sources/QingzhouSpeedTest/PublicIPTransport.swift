import Foundation
import Network
import Security
import QingzhouCore

public enum PublicIPTransport {
    /// Resolve using the physical interface's system resolver, then bind TLS to that same interface.
    /// Never fall back to an unbound connection or to a synthetic FakeDNS address.
    public static func direct() async throws -> Data {
        guard let interface = await DirectInterfaceResolver.shared.currentPhysicalInterface() else {
            throw URLError(.notConnectedToInternet)
        }
        let resolved = await DirectDNSResolver().resolve(PublicIPProbe.host, interfaceIndex: UInt32(interface.index), timeout: 3)
        guard case .success(let addresses) = resolved else { throw URLError(.cannotFindHost) }
        var lastError: Error = URLError(.cannotConnectToHost)
        for address in addresses.prefix(2) {
            try Task.checkCancellation()
            do { return try await PublicIPTLSRequest(host: address, port: 443, interface: interface).run() }
            catch { lastError = error }
        }
        throw lastError
    }

    /// The tunnel exposes a loopback TCP forward to the fixed HTTPS target, forced through proxy.
    public static func proxy(port: UInt16) async throws -> Data {
        guard port > 0 else { throw URLError(.badURL) }
        return try await PublicIPTLSRequest(host: "127.0.0.1", port: port, interface: nil).run()
    }
}

/// One request, one serial queue, one completion (including cancellation and timeout).
private final class PublicIPTLSRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qingzhou.public-ip")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished: Result<Data, Error>?
    private var bytes = Data()

    init(host: String, port: UInt16, interface: NWInterface?) {
        let tls = NWProtocolTLS.Options()
        // Apple's TLS options use this name for BOTH SNI and peer certificate validation.
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, PublicIPProbe.host)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredInterface = interface
        parameters.preferNoProxies = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let finished = self.finished { continuation.resume(with: finished); return }
                    self.continuation = continuation
                    self.connection.stateUpdateHandler = { [weak self] state in
                        guard let self, self.finished == nil else { return }
                        switch state {
                        case .ready:
                            let request = "GET \(PublicIPProbe.path) HTTP/1.1\r\nHost: \(PublicIPProbe.host)\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
                            self.connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
                                guard let self else { return }
                                if let error { self.finish(.failure(error)) } else { self.receive() }
                            })
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 8) { self.finish(.failure(URLError(.timedOut))) }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func receive() {
        guard finished == nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.finished == nil else { return }
            if let error { self.finish(.failure(error)); return }
            if let data { self.bytes.append(data) }
            do {
                if let body = try PublicIPHTTPResponse.body(self.bytes, complete: complete) {
                    self.finish(.success(body))
                } else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard finished == nil else { return }
        finished = result
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Bounded HTTP/1 response framing. Reject redirects, compression, ambiguous lengths and truncation.
enum PublicIPHTTPResponse {
    static func body(_ data: Data, complete: Bool) throws -> Data? {
        func incomplete() throws -> Data? {
            if complete { throw URLError(.badServerResponse) }; return nil
        }
        guard data.count <= PublicIPProbe.maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return try incomplete() }
        guard let header = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = header.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])), status[1] == "200" else {
            throw URLError(.badServerResponse)
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw URLError(.badServerResponse) }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if fields[name] != nil && ["content-length", "transfer-encoding", "content-encoding"].contains(name) { throw URLError(.badServerResponse) }
            fields[name] = value
        }
        guard fields["content-encoding"] == nil || fields["content-encoding"] == "identity" else { throw URLError(.badServerResponse) }
        let payload = Data(data[split.upperBound...])
        if let encoding = fields["transfer-encoding"] {
            guard encoding == "chunked", fields["content-length"] == nil else { throw URLError(.badServerResponse) }
            var position = 0
            var decoded = Data()
            while true {
                guard let end = payload.range(of: Data("\r\n".utf8), in: position..<payload.count) else { return try incomplete() }
                let sizeText = String(data: payload[position..<end.lowerBound], encoding: .utf8)?.split(separator: ";", omittingEmptySubsequences: false).first
                guard let sizeText, let size = Int(sizeText, radix: 16), size >= 0, size <= PublicIPProbe.maximumResponseBytes else { throw URLError(.badServerResponse) }
                position = end.upperBound
                guard payload.count - position >= size + 2 else { return try incomplete() }
                if size == 0 {
                    // Accept empty trailer or a fully terminated trailer block.
                    if payload[position..<position+2] == Data("\r\n".utf8) { return decoded }
                    guard payload.range(of: Data("\r\n\r\n".utf8), in: position..<payload.count) != nil else { return try incomplete() }
                    return decoded
                }
                guard payload[position+size..<position+size+2] == Data("\r\n".utf8) else { throw URLError(.badServerResponse) }
                decoded.append(payload[position..<position+size])
                position += size + 2
            }
        }
        if let value = fields["content-length"] {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(value), length <= PublicIPProbe.maximumResponseBytes else { throw URLError(.badServerResponse) }
            guard payload.count >= length else { return try incomplete() }
            guard payload.count == length else { throw URLError(.badServerResponse) }
            return payload
        }
        return complete ? payload : nil
    }
}
