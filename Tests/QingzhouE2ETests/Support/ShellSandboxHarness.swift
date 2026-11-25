#if os(macOS)
import Foundation

final class ShellSandboxHarness: @unchecked Sendable {
    let rootURL: URL
    let baseURL: URL
    let binURL: URL
    let logsURL: URL
    let launchDaemonsURL: URL
    let homeURL: URL
    let stateURL: URL
    let callsLogURL: URL
    let anchorRulesURL: URL
    private let lock = NSLock()
    private var asyncProcesses: [Process] = []

    var xrayConfigURL: URL {
        homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Group Containers")
            .appendingPathComponent("group.com.sbraveyoung.qingzhou")
            .appendingPathComponent("xray-config.json")
    }

    var plistURL: URL {
        launchDaemonsURL.appendingPathComponent("com.sbraveyoung.qingzhou.guard.plist")
    }

    init(repoRoot: URL) throws {
        self.rootURL = try TestFixtures.makeTempDirectory(prefix: "qz-shell-sandbox")
        self.baseURL = rootURL.appendingPathComponent("base")
        self.binURL = rootURL.appendingPathComponent("bin")
        self.logsURL = rootURL.appendingPathComponent("logs")
        self.launchDaemonsURL = rootURL.appendingPathComponent("launchdaemons")
        self.homeURL = rootURL.appendingPathComponent("home")
        self.stateURL = rootURL.appendingPathComponent("state")
        self.callsLogURL = rootURL.appendingPathComponent("calls.log")
        self.anchorRulesURL = stateURL.appendingPathComponent("anchor_rules")

        let fm = FileManager.default
        for dir in [baseURL, binURL, logsURL, launchDaemonsURL, homeURL, stateURL,
                    xrayConfigURL.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "".write(to: callsLogURL, atomically: true, encoding: .utf8)
        try "1".write(to: stateURL.appendingPathComponent("nc_ok"), atomically: true, encoding: .utf8)
        try "utun9".write(to: stateURL.appendingPathComponent("ifconfig_utuns"), atomically: true, encoding: .utf8)
        try "1".write(to: stateURL.appendingPathComponent("pf_enabled"), atomically: true, encoding: .utf8)

        let guardDir = repoRoot.appendingPathComponent("Tools/qingzhou-guard")
        // Copy pf config verbatim
        let confSrc = guardDir.appendingPathComponent("pf/qingzhou-guard.conf")
        try fm.copyItem(at: confSrc, to: baseURL.appendingPathComponent("qingzhou-guard.conf"))

        // Copy & rewrite hardcoded root paths to sandbox paths in scripts
        for script in ["enable.sh", "guard-run.sh", "off.sh", "uninstall.sh"] {
            let src = guardDir.appendingPathComponent(script)
            var content = try String(contentsOf: src, encoding: .utf8)
            content = content.replacingOccurrences(
                of: "/Library/Application Support/qingzhou-guard",
                with: baseURL.path
            )
            content = content.replacingOccurrences(
                of: "/Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist",
                with: plistURL.path
            )
            content = content.replacingOccurrences(
                of: "/var/log/qingzhou-relay.log",
                with: logsURL.appendingPathComponent("qingzhou-relay.log").path
            )
            content = content.replacingOccurrences(
                of: "/var/log/qingzhou-guard.log",
                with: logsURL.appendingPathComponent("qingzhou-guard.log").path
            )
            content = content.replacingOccurrences(
                of: "/usr/sbin/systemsetup",
                with: "systemsetup"
            )
            let dst = baseURL.appendingPathComponent(script)
            try content.write(to: dst, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }

        try installStubs()
    }

    private func installStubs() throws {
        try writeStub("id", body: """
        #!/bin/sh
        if [ "${1:-}" = "-u" ]; then
          echo 0
          exit 0
        fi
        exec /usr/bin/id "$@"
        """)

        try writeStub("nc", body: """
        #!/bin/sh
        echo "nc $*" >> "\(callsLogURL.path)"
        if [ "$(cat "\(stateURL.path)/nc_ok" 2>/dev/null)" = "1" ]; then
          exit 0
        fi
        exit 1
        """)

        try writeStub("stat", body: """
        #!/bin/sh
        if [ "$*" = "-f %Su /dev/console" ]; then
          echo "sandboxuser"
          exit 0
        fi
        exec /usr/bin/stat "$@"
        """)

        try writeStub("dscl", body: """
        #!/bin/sh
        echo "dscl $*" >> "\(callsLogURL.path)"
        echo "NFSHomeDirectory: \(homeURL.path)"
        """)

        try writeStub("ifconfig", body: """
        #!/bin/sh
        UTUNS="$(cat "\(stateURL.path)/ifconfig_utuns" 2>/dev/null)"
        if [ "${1:-}" = "-l" ]; then
          if [ -n "$UTUNS" ]; then
            echo "lo0 en0 $UTUNS"
          else
            echo "lo0 en0"
          fi
          exit 0
        fi
        for u in $UTUNS; do
          if [ "${1:-}" = "$u" ]; then
            echo "${u}: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500"
            echo "\tinet 10.0.10.1 --> 10.0.10.1 netmask 0xffff0000"
            exit 0
          fi
        done
        exit 1
        """)

        try writeStub("pfctl", body: """
        #!/bin/sh
        echo "pfctl $*" >> "\(callsLogURL.path)"
        # Never allow -d in sandbox
        for arg in "$@"; do
          if [ "$arg" = "-d" ]; then
            echo "FORBIDDEN pfctl -d" >> "\(callsLogURL.path)"
            exit 99
          fi
        done
        if [ "${1:-}" = "-n" ]; then
          exit 0
        fi
        if [ "${1:-}" = "-s" ] && [ "${2:-}" = "info" ]; then
          if [ "$(cat "\(stateURL.path)/pf_enabled" 2>/dev/null)" = "1" ]; then
            echo "Status: Enabled"
          else
            echo "Status: Disabled"
          fi
          exit 0
        fi
        if [ "${1:-}" = "-E" ]; then
          echo "1" > "\(stateURL.path)/pf_enabled"
          echo "Token : 987654"
          exit 0
        fi
        if [ "${1:-}" = "-X" ]; then
          echo "0" > "\(stateURL.path)/pf_enabled"
          exit 0
        fi
        if [ "${1:-}" = "-s" ] && [ "${2:-}" = "rules" ]; then
          cat "\(anchorRulesURL.path)" 2>/dev/null || true
          exit 0
        fi
        if [ "${1:-}" = "-a" ] && [ "${3:-}" = "-F" ] && [ "${4:-}" = "all" ]; then
          rm -f "\(anchorRulesURL.path)"
          exit 0
        fi
        if [ "${1:-}" = "-a" ] && [ "${3:-}" = "-f" ] && [ -n "${4:-}" ]; then
          cp "${4}" "\(anchorRulesURL.path)"
          exit 0
        fi
        exit 0
        """)

        try writeStub("systemsetup", body: """
        #!/bin/sh
        echo "systemsetup $*" >> "\(callsLogURL.path)"
        exit 0
        """)

        try writeStub("launchctl", body: """
        #!/bin/sh
        echo "launchctl $*" >> "\(callsLogURL.path)"
        if [ "${1:-}" = "print" ]; then
          exit 1
        fi
        exit 0
        """)

        try writeStub("pkill", body: """
        #!/bin/sh
        echo "pkill $*" >> "\(callsLogURL.path)"
        if [ -f "\(stateURL.path)/relay.pid" ]; then
          PID="$(cat "\(stateURL.path)/relay.pid" 2>/dev/null)"
          if [ -n "$PID" ] && ps -p "$PID" -o args= 2>/dev/null | grep -q "\(baseURL.path)/qingzhou-relay"; then
            kill "$PID" 2>/dev/null || true
          fi
        fi
        exit 0
        """)

        // Stub qingzhou-relay binary inside baseURL
        let relayBin = baseURL.appendingPathComponent("qingzhou-relay")
        let relayBody = """
        #!/bin/sh
        PID_FILE="\(stateURL.path)/relay.pid"
        SLEEP_PID=""
        cleanup_and_exit() {
          [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null || true
          rm -f "$PID_FILE"
          exit 0
        }
        trap 'rm -f "$PID_FILE"' EXIT
        trap cleanup_and_exit INT TERM
        echo "$$" > "$PID_FILE"
        echo "relay $*" >> "\(callsLogURL.path)"
        : > "\(logsURL.appendingPathComponent("qingzhou-relay.log").path)"
        while [ -d "\(stateURL.path)" ] && [ ! -f "\(stateURL.path)/stop_relay" ]; do
          sleep 0.2 &
          SLEEP_PID=$!
          wait "$SLEEP_PID" 2>/dev/null || true
          SLEEP_PID=""
        done
        exit 0
        """
        try relayBody.write(to: relayBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relayBin.path)
    }

    private func writeStub(_ name: String, body: String) throws {
        let url = binURL.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func setUtuns(_ value: String) throws {
        try value.write(to: stateURL.appendingPathComponent("ifconfig_utuns"), atomically: true, encoding: .utf8)
    }

    func setRelayReachable(_ reachable: Bool) throws {
        try (reachable ? "1" : "0").write(
            to: stateURL.appendingPathComponent("nc_ok"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeXrayConfig(_ json: String) throws {
        try json.write(to: xrayConfigURL, atomically: true, encoding: .utf8)
    }

    func writeFreshRelayLog() throws {
        let logURL = logsURL.appendingPathComponent("qingzhou-relay.log")
        try "2026-11-25T00:00:00Z CONNECT 127.0.0.1\n".write(to: logURL, atomically: true, encoding: .utf8)
    }

    func setRelayLogAgeSeconds(_ secondsAgo: TimeInterval) throws {
        let logURL = logsURL.appendingPathComponent("qingzhou-relay.log")
        try writeFreshRelayLog()
        let past = Date().addingTimeInterval(-secondsAgo)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: logURL.path)
    }

    func triggerStopRelay() throws {
        try "1".write(to: stateURL.appendingPathComponent("stop_relay"), atomically: true, encoding: .utf8)
    }

    func readCallsLog() -> String {
        (try? String(contentsOf: callsLogURL, encoding: .utf8)) ?? ""
    }

    func readAnchorRules() -> String {
        (try? String(contentsOf: anchorRulesURL, encoding: .utf8)) ?? ""
    }

    func sandboxEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let sysPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(binURL.path):\(sysPath)"
        env["SUDO_USER"] = "sandboxuser"
        return env
    }

    func runScript(_ scriptName: String) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [baseURL.appendingPathComponent(scriptName).path]
        p.environment = sandboxEnvironment()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out, err)
    }

    func startScriptAsync(_ scriptName: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [baseURL.appendingPathComponent(scriptName).path]
        p.environment = sandboxEnvironment()
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        lock.lock()
        asyncProcesses.append(p)
        lock.unlock()
        return p
    }

    private func isLiveSandboxRelayPID(_ pid: Int32) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "args="]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let args = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return args.contains(baseURL.appendingPathComponent("qingzhou-relay").path)
    }

    func cleanup() {
        try? triggerStopRelay()

        lock.lock()
        let procs = asyncProcesses
        asyncProcesses.removeAll()
        lock.unlock()
        for proc in procs where proc.isRunning {
            proc.terminate()
        }
        for proc in procs where proc.isRunning {
            proc.waitUntilExit()
        }

        let pidFile = stateURL.appendingPathComponent("relay.pid")
        if FileManager.default.fileExists(atPath: pidFile.path),
           let pidStr = try? String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), pid > 0,
           isLiveSandboxRelayPID(pid) {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline && isLiveSandboxRelayPID(pid) {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if isLiveSandboxRelayPID(pid) {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: rootURL)
    }

    deinit {
        cleanup()
    }
}
#endif
