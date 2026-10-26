import Foundation
import Network
import dnssd

/// 使用当前物理接口的系统解析器；不新增第三方 DNS 服务。
/// 显式解析后再连接 IP，防止 FakeDNS 虚拟地址被拿去物理网卡直连。
final class DirectDNSResolver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qingzhou.direct-dns")
    private var reference: DNSServiceRef?
    private var batch = DirectAddressBatch()
    private var continuation: CheckedContinuation<Result<[String], DirectProbeFailure>, Never>?
    private var finished: Result<[String], DirectProbeFailure>?

    static func isSynthetic(_ host: String) -> Bool {
        let bytes = host.split(separator: ".").compactMap { UInt8($0) }
        return bytes.count == 4 && bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)
    }

    func resolve(_ host: String, interfaceIndex: UInt32, timeout: TimeInterval, ipv6: Bool = false) async -> Result<[String], DirectProbeFailure> {
        if Self.isSynthetic(host) { return .failure(.syntheticAddress) }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return .success([host]) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    if let finished = self.finished { continuation.resume(returning: finished); return }
                    self.continuation = continuation
                    let result = DNSServiceGetAddrInfo(&self.reference, 0, interfaceIndex,
                        DNSServiceProtocol(ipv6 ? kDNSServiceProtocol_IPv6 : kDNSServiceProtocol_IPv4), host, { _, flags, _, error, _, address, _, context in
                            guard let context else { return }
                            let request = Unmanaged<DirectDNSResolver>.fromOpaque(context).takeUnretainedValue()
                            guard error == 0, let address else { request.finish(.failure(.dnsFailed)); return }
                            guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 else { return }
                            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                                request.finish(.failure(.dnsFailed)); return
                            }
                            let ip = String(cString: buffer)
                            if let result = request.batch.append(ip, moreComing: flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0) {
                                request.finish(result)
                            }
                        }, Unmanaged.passUnretained(self).toOpaque())
                    guard result == 0, let reference = self.reference else { self.finish(.failure(.dnsFailed)); return }
                    guard DNSServiceSetDispatchQueue(reference, self.queue) == 0 else {
                        self.finish(.failure(.dnsFailed)); return
                    }
                    self.queue.asyncAfter(deadline: .now() + max(0.01, timeout)) { self.finish(.failure(.dnsFailed)) }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(.cancelled)) }
        }
    }

    private func finish(_ result: Result<[String], DirectProbeFailure>) {
        guard finished == nil else { return }
        finished = result
        if let reference { DNSServiceRefDeallocate(reference); self.reference = nil }
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// 收集同批 DNS 回调，过滤虚拟地址；候选上限限制连接开销。
struct DirectAddressBatch {
    private var addresses: [String] = []
    mutating func append(_ address: String, moreComing: Bool) -> Result<[String], DirectProbeFailure>? {
        if !DirectDNSResolver.isSynthetic(address), !addresses.contains(address) { addresses.append(address) }
        guard !moreComing || addresses.count >= 4 else { return nil }
        return addresses.isEmpty ? .failure(.syntheticAddress) : .success(addresses)
    }
}
