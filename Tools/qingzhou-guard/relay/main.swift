// qingzhou-relay —— 供 pf 断网开关使用的「root 出口」CLI 入口。
// 核心逻辑位于 Sources/QingzhouGuardRelayCore/，此处仅负责解析命令行参数、
// 校验独立分离的转发/控制凭据、启动 RelayServer 并进入 dispatchMain()。

import Foundation

#if canImport(QingzhouGuardRelayCore)
import QingzhouGuardRelayCore
#endif

let cfg = RelayConfig.parseArgs()
let logger = RelayLogger(logPath: cfg.logPath)

guard cfg.port > 0, cfg.controlPort > 0 else {
    logger.log("FATAL: 非法端口 port=\(cfg.port) controlPort=\(cfg.controlPort)")
    exit(2)
}

guard let creds = RelayAuthCredentials.load(from: cfg.authFile) else {
    // fail closed：任一凭据缺失、为空或转发/控制凭据相同都拒绝启动
    logger.log("FATAL: 无法从 \(cfg.authFile) 读取有效的分离转发/控制凭据，拒绝启动")
    exit(2)
}

let server = RelayServer(config: cfg, creds: creds, logger: logger)
do {
    _ = try server.start { _ in
        exit(1)
    }
} catch {
    logger.log("FATAL: 无法监听 127.0.0.1:\(cfg.port) — \(error)")
    exit(2)
}

dispatchMain()
