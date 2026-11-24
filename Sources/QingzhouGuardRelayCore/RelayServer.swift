import Foundation
import Network

/// 封装转发监听器与控制监听器的完整中继服务。
public final class RelayServer: @unchecked Sendable {
    public let config: RelayConfig
    public let creds: RelayAuthCredentials
    public let logger: RelayLogger
    public let dns: RelayDNS
    public let physicalEgress: PhysicalEgress
    public let timeZoneController: TimeZoneController

    private let clientRegistry = SessionRegistry<ClientSession>()
    private let controlRegistry = SessionRegistry<ControlSession>()
    private let requirePhysicalInterface: Bool

    private var forwardListener: NWListener?
    private var controlListener: NWListener?
    private let listenerQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.relay.listener")

    public init(
        config: RelayConfig,
        creds: RelayAuthCredentials,
        logger: RelayLogger? = nil,
        dns: RelayDNS = RelayDNS(),
        timeZoneProvider: TimeZoneProviding = SystemTimeZoneProvider(),
        requirePhysicalInterface: Bool = true
    ) {
        let log = logger ?? RelayLogger(logPath: config.logPath)
        self.config = config
        self.creds = creds
        self.logger = log
        self.dns = dns
        self.physicalEgress = PhysicalEgress(logger: log)
        self.timeZoneController = TimeZoneController(
            tzOrigPath: config.tzOrigPath,
            provider: timeZoneProvider,
            logger: log
        )
        self.requirePhysicalInterface = requirePhysicalInterface
    }

    public func start(
        onFatalForwardFailure: (@Sendable (Error?) -> Void)? = nil
    ) throws -> (forwardPort: UInt16, controlPort: UInt16?) {
        let fPort: NWEndpoint.Port = config.port == 0
            ? .any
            : (NWEndpoint.Port(rawValue: config.port) ?? .any)
        let fParams = NWParameters.tcp
        fParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: fPort)
        fParams.allowLocalEndpointReuse = true

        let fListener = try NWListener(using: fParams)
        let forwardReadySem = DispatchSemaphore(value: 0)
        final class ReadyState: @unchecked Sendable {
            let lock = NSLock()
            var port: UInt16 = 0
            var error: Error?
            var signaled = false
        }
        let fState = ReadyState()

        fListener.stateUpdateHandler = { [logger] state in
            switch state {
            case .ready:
                let actualPort = fListener.port?.rawValue ?? self.config.port
                logger.log("listening on 127.0.0.1:\(actualPort)（仅 CONNECT + 转发凭据认证）")
                fState.lock.lock()
                fState.port = actualPort
                let shouldSignal = !fState.signaled
                fState.signaled = true
                fState.lock.unlock()
                if shouldSignal { forwardReadySem.signal() }
            case .failed(let error):
                logger.log("FATAL: listener failed — \(error)")
                fState.lock.lock()
                fState.error = error
                let shouldSignal = !fState.signaled
                fState.signaled = true
                fState.lock.unlock()
                if shouldSignal { forwardReadySem.signal() }
                onFatalForwardFailure?(error)
            default:
                break
            }
        }

        fListener.newConnectionHandler = { [self] connection in
            ClientSession(
                connection,
                creds: creds.forwarding,
                registry: clientRegistry,
                dns: dns,
                egressProvider: { [physicalEgress] in physicalEgress.current() },
                requirePhysicalInterface: requirePhysicalInterface,
                logger: logger
            ).start()
        }

        if requirePhysicalInterface {
            physicalEgress.start()
        }
        self.forwardListener = fListener
        fListener.start(queue: listenerQueue)
        forwardReadySem.wait()

        fState.lock.lock()
        let forwardErr = fState.error
        let forwardPort = fState.port
        fState.lock.unlock()

        if let err = forwardErr {
            stop()
            throw err
        }

        var actualControlPort: UInt16?
        let cPort: NWEndpoint.Port = config.controlPort == 0
            ? .any
            : (NWEndpoint.Port(rawValue: config.controlPort) ?? .any)
        let cParams = NWParameters.tcp
        cParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: cPort)
        cParams.allowLocalEndpointReuse = true

        do {
            let cListener = try NWListener(using: cParams)
            let cReadySem = DispatchSemaphore(value: 0)
            let cState = ReadyState()
            cListener.stateUpdateHandler = { [logger] state in
                switch state {
                case .ready:
                    let actualPort = cListener.port?.rawValue ?? self.config.controlPort
                    logger.log("controller listening on 127.0.0.1:\(actualPort)（时区指令，控制凭据认证）")
                    cState.lock.lock()
                    cState.port = actualPort
                    let shouldSignal = !cState.signaled
                    cState.signaled = true
                    cState.lock.unlock()
                    if shouldSignal { cReadySem.signal() }
                case .failed(let error):
                    logger.log("控制端口失败：\(error)")
                    cState.lock.lock()
                    cState.error = error
                    let shouldSignal = !cState.signaled
                    cState.signaled = true
                    cState.lock.unlock()
                    if shouldSignal { cReadySem.signal() }
                default:
                    break
                }
            }
            cListener.newConnectionHandler = { [self] connection in
                ControlSession(
                    connection,
                    creds: creds.control,
                    timeZoneController: timeZoneController,
                    registry: controlRegistry
                ).start()
            }
            self.controlListener = cListener
            cListener.start(queue: listenerQueue)
            cReadySem.wait()
            cState.lock.lock()
            let controlErr = cState.error
            let controlPort = cState.port
            cState.lock.unlock()
            if controlErr == nil {
                actualControlPort = controlPort
            }
        } catch {
            logger.log("警告：控制端口 \(config.controlPort) 无法监听（\(error)）—— 时区跟随不可用，代理不受影响")
        }

        return (forwardPort, actualControlPort)
    }

    public func stop() {
        forwardListener?.cancel()
        forwardListener = nil
        controlListener?.cancel()
        controlListener = nil
        physicalEgress.stop()
    }
}
