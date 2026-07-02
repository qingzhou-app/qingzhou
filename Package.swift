// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Qingzhou",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "QingzhouCore",         targets: ["QingzhouCore"]),
        .library(name: "QingzhouProtocols",    targets: ["QingzhouProtocols"]),
        .library(name: "QingzhouSubscription", targets: ["QingzhouSubscription"]),
        .library(name: "QingzhouRules",        targets: ["QingzhouRules"]),
        .library(name: "QingzhouSpeedTest",    targets: ["QingzhouSpeedTest"]),
        .library(name: "QingzhouLogging",      targets: ["QingzhouLogging"]),
        .library(name: "QingzhouApp",          targets: ["QingzhouApp"]),
        .library(name: "XrayConfig",      targets: ["XrayConfig"]),
        .library(name: "XrayCore",        targets: ["XrayCore"])
    ],
    dependencies: [
        // Yams：Swift YAML 解析器，用于 Clash / Mihomo / Stash 配置导入。
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        // resources: cn-domains.txt —— CN 域名归属判定的内置后缀表（见 CNDomains.swift）
        .target(name: "QingzhouCore", resources: [.copy("Resources/cn-domains.txt")]),
        .target(
            name: "QingzhouProtocols",
            dependencies: [
                "QingzhouCore",
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .target(name: "QingzhouSubscription", dependencies: ["QingzhouCore", "QingzhouProtocols", "QingzhouLogging"]),
        .target(name: "QingzhouRules",        dependencies: ["QingzhouCore", "QingzhouLogging"]),
        .target(name: "QingzhouSpeedTest",    dependencies: ["QingzhouCore", "QingzhouLogging"]),
        .target(name: "QingzhouLogging",      dependencies: ["QingzhouCore"]),
        .target(
            name: "QingzhouApp",
            dependencies: [
                "QingzhouCore", "QingzhouProtocols", "QingzhouSubscription",
                "QingzhouRules", "QingzhouSpeedTest", "QingzhouLogging"
                // QingzhouApp 故意不依赖 XrayCore —— XrayCore 拖入 LibXray.xcframework（85 MB
                // Go runtime），dyld 在主 App 启动时强制加载完才进 main()，会黑屏 1–3 秒。
                // share link → 完整 xray 配置 的转换挪到了 Extension 里做，
                // 见 Apps/Tunnel-Shared/PacketTunnelProvider.swift。
            ]
        ),

        // XrayConfig: 把 Node 转成 xray-core 的 outbound JSON，再加上 inbound / routing / dns
        // 包装成完整 xray 配置。**不依赖 LibXray**（纯 Swift），所以可以在主 App 和单测里用，
        // 不会拖进 85 MB Go runtime。
        .target(name: "XrayConfig", dependencies: ["QingzhouCore"]),

        .testTarget(name: "QingzhouCoreTests",         dependencies: ["QingzhouCore"]),
        .testTarget(name: "QingzhouProtocolsTests",    dependencies: ["QingzhouProtocols"]),
        .testTarget(name: "QingzhouSubscriptionTests", dependencies: ["QingzhouSubscription"]),
        .testTarget(name: "QingzhouRulesTests",        dependencies: ["QingzhouRules"]),
        .testTarget(name: "QingzhouSpeedTestTests",    dependencies: ["QingzhouSpeedTest"]),
        .testTarget(name: "QingzhouLoggingTests",      dependencies: ["QingzhouLogging"]),
        .testTarget(name: "QingzhouAppTests",          dependencies: ["QingzhouApp"]),
        .testTarget(name: "XrayConfigTests",      dependencies: ["XrayConfig"]),

        // ─────────────────────────────────────────────────────────────────────
        // XrayCore：Swift 包装 LibXray.xcframework（xray-core 的 MIT 移动端 binding）。
        // xcframework 由 scripts/build-libxray.sh 通过 libXray 上游脚本构建产出，
        // 文件不入库（体积大，~380MB）；首次构建后落在 Frameworks/LibXray.xcframework。
        // ─────────────────────────────────────────────────────────────────────
        .binaryTarget(
            name: "LibXray",
            path: "Frameworks/LibXray.xcframework"
        ),
        .target(
            name: "XrayCore",
            dependencies: ["LibXray", "QingzhouCore", "QingzhouLogging", "XrayConfig"],
            linkerSettings: [
                // libXray 内部用 res_9_* DNS resolver API（Darwin libresolv）
                .linkedLibrary("resolv")
            ]
        ),
        .testTarget(name: "XrayCoreTests", dependencies: ["XrayCore"])
    ]
)
