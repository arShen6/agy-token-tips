import Darwin
import Foundation

enum QuotaModelFamily: String, Codable, Equatable {
    case gemini
    case thirdParty // Claude / GPT
    case unknown

    static func infer(from modelName: String) -> QuotaModelFamily {
        let low = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty || low == "—" { return .unknown }
        if low.contains("gemini") || low.contains("orchestrator") || low.contains("neon")
            || low.contains("carbon") || low.contains("argon") || low.contains("hydrogen") {
            return .gemini
        }
        if low.contains("claude") || low.contains("opus") || low.contains("sonnet")
            || low.contains("haiku") || low.contains("gpt") || low.contains("openai") || low.contains("o1") || low.contains("o3") {
            return .thirdParty
        }
        return .unknown
    }
}

struct QuotaBucket: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let window: String // "5h" | "weekly" | other
    let remainingFraction: Double? // 0.0 ... 1.0
    let remainingAmount: Double?
    let resetTimeISO: String?
    let disabled: Bool

    var resetDate: Date? {
        guard let iso = resetTimeISO, !iso.isEmpty else { return nil }
        return QuotaDateParser.parse(iso)
    }

    var isFiveHour: Bool {
        window.lowercased().contains("5h") || id.lowercased().contains("5h")
    }

    var isWeekly: Bool {
        let w = window.lowercased()
        let i = id.lowercased()
        return w.contains("week") || w.contains("7d") || i.contains("week") || i.contains("7d")
    }

    func effectiveFraction(at now: Date) -> Double? {
        if let reset = resetDate, reset <= now {
            return 1.0
        }
        return remainingFraction
    }

    func isAwaitingResetConfirm(at now: Date) -> Bool {
        if let reset = resetDate, reset <= now { return true }
        return false
    }
}

struct QuotaGroup: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let family: QuotaModelFamily
    let buckets: [QuotaBucket]

    var fiveHourBucket: QuotaBucket? {
        buckets.first(where: { $0.isFiveHour }) ?? buckets.first
    }

    var weeklyBucket: QuotaBucket? {
        buckets.first(where: { $0.isWeekly })
    }

    func displayName(zh: Bool) -> String {
        switch family {
        case .gemini: return zh ? "Gemini 模型组" : "Gemini Models"
        case .thirdParty: return zh ? "Claude / GPT 组" : "Claude & GPT"
        case .unknown: return name
        }
    }
}

struct QuotaSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let groups: [QuotaGroup]
    let source: String // "cli" | "cache"

    func group(for family: QuotaModelFamily) -> QuotaGroup? {
        guard family != .unknown else { return groups.first }
        return groups.first(where: { $0.family == family }) ?? groups.first
    }
}

enum QuotaFetchState: Equatable {
    case idle
    case loading
    case ready
    case cliMissing
    case notSignedIn
    case timeout
    case failed(String)

    var isError: Bool {
        switch self {
        case .cliMissing, .notSignedIn, .timeout, .failed: return true
        default: return false
        }
    }
}

enum QuotaDateParser {
    private static let lock = NSLock()
    private static var cache: [String: Date] = [:]
    private static let fmtFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fmtStd: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ iso: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[iso] { return hit }
        let parsed = fmtFrac.date(from: iso) ?? fmtStd.date(from: iso)
        if let parsed {
            if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
            cache[iso] = parsed
        }
        return parsed
    }
}

/// Official Antigravity quota reader powered solely by `agy --output-format json -p /usage`.
/// Uses isolated process group (`POSIX_SPAWN_SETPGROUP`) + non-blocking `DispatchSource` pipe
/// readers on a single serial queue so timeouts kill all grandchildren with zero FD/thread leaks
/// and zero data races.
final class QuotaService: @unchecked Sendable {
    private let cacheURL: URL
    private let executableOverride: String?
    private let timeoutSeconds: TimeInterval
    private let ioQueue = DispatchQueue(label: "io.tokenlens.quota", qos: .utility)
    private let stateLock = NSLock()
    private var inFlight = false
    private var lastAttemptAt: Date = .distantPast
    private var consecutiveFailures = 0

    private static let maxOutputBytes = 2 * 1024 * 1024
    private static let backoffSeconds: [TimeInterval] = [60, 120, 300, 600]

    init(executableOverride: String? = nil, timeoutSeconds: TimeInterval = 20.0) {
        self.executableOverride = executableOverride
        self.timeoutSeconds = timeoutSeconds
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport.appendingPathComponent("TokenLensHUD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("quota-cache.json")
    }

    func loadCachedSnapshot() -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let snap = try? dec.decode(QuotaSnapshot.self, from: data),
              !snap.groups.isEmpty else {
            return nil
        }
        if Date().timeIntervalSince(snap.fetchedAt) > 24 * 3600 {
            return nil
        }
        return snap
    }

    private func saveCachedSnapshot(_ snapshot: QuotaSnapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func resolveAgyExecutable() -> String? {
        let fm = FileManager.default
        if let override = executableOverride {
            return fm.isExecutableFile(atPath: override) ? override : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/usr/bin/agy"
        ]
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    func fetchIfAllowed(
        force: Bool,
        currentSnapshot: QuotaSnapshot?,
        maxAge: TimeInterval,
        onStateChange: @escaping @Sendable (QuotaFetchState) -> Void,
        onResult: @escaping @Sendable (QuotaSnapshot?, QuotaFetchState) -> Void
    ) {
        // Respect macOS Low Power Mode for automatic background quota refreshes
        if !force && ProcessInfo.processInfo.isLowPowerModeEnabled {
            return
        }

        let now = Date()
        stateLock.lock()
        if inFlight {
            stateLock.unlock()
            return
        }
        if force {
            if consecutiveFailures == 0 && now.timeIntervalSince(lastAttemptAt) < 8 {
                stateLock.unlock()
                return
            }
            consecutiveFailures = 0
        } else {
            if let snap = currentSnapshot {
                let age = now.timeIntervalSince(snap.fetchedAt)
                let anyResetPassed = snap.groups.flatMap(\.buckets).contains { b in
                    guard let r = b.resetDate else { return false }
                    return r > snap.fetchedAt && now.timeIntervalSince(r) >= 15
                }
                if age < maxAge && !anyResetPassed {
                    stateLock.unlock()
                    return
                }
            }
            if consecutiveFailures > 0 {
                let idx = min(consecutiveFailures - 1, Self.backoffSeconds.count - 1)
                if now.timeIntervalSince(lastAttemptAt) < Self.backoffSeconds[idx] {
                    stateLock.unlock()
                    return
                }
            }
        }
        inFlight = true
        lastAttemptAt = now
        stateLock.unlock()

        onStateChange(.loading)

        spawnAndReadAgyUsage { [weak self] snapshot, state in
            guard let self else { return }
            self.stateLock.lock()
            self.inFlight = false
            if snapshot != nil {
                self.consecutiveFailures = 0
            } else {
                self.consecutiveFailures += 1
            }
            self.stateLock.unlock()

            if let snapshot {
                self.saveCachedSnapshot(snapshot)
            }
            onResult(snapshot, state)
        }
    }

    /// Spawns `agy` inside its own isolated process group (`POSIX_SPAWN_SETPGROUP`) and drains
    /// stdout/stderr asynchronously via `DispatchSourceRead` on `ioQueue` (zero extra GCD threads,
    /// deterministic process-group SIGTERM -> SIGKILL cleanup, zero FD leaks).
    func spawnAndReadAgyUsage(completion: @escaping @Sendable (QuotaSnapshot?, QuotaFetchState) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let agyPath = self.resolveAgyExecutable() else {
                completion(nil, .cliMissing)
                return
            }

            var outPipe: [Int32] = [-1, -1]
            var errPipe: [Int32] = [-1, -1]
            guard Darwin.pipe(&outPipe) == 0 else {
                completion(nil, .failed("pipe error"))
                return
            }
            guard Darwin.pipe(&errPipe) == 0 else {
                Darwin.close(outPipe[0]); Darwin.close(outPipe[1])
                completion(nil, .failed("pipe error"))
                return
            }

            // Close-on-exec & non-blocking on parent read ends
            _ = fcntl(outPipe[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(errPipe[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(outPipe[0], F_SETFL, O_NONBLOCK)
            _ = fcntl(errPipe[0], F_SETFL, O_NONBLOCK)

            let devNull = Darwin.open("/dev/null", O_RDONLY)

            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            if devNull >= 0 {
                posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
            }
            posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
            posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, errPipe[1])
            if devNull >= 0 {
                posix_spawn_file_actions_addclose(&fileActions, devNull)
            }

            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            // Put child & all grandchildren into a dedicated process group (pgid == childPid)
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attr, 0)

            let args = [
                agyPath,
                "--settings",
                "{\"disableSlashCommands\":false,\"statusLine\":{\"enabled\":false},\"useG1Credits\":false}",
                "--output-format", "json",
                "-p", "/usage"
            ]

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var envDict = ProcessInfo.processInfo.environment
            let extraPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            envDict["PATH"] = (envDict["PATH"]?.isEmpty == false) ? "\(extraPath):\(envDict["PATH"]!)" : extraPath
            let envStrings = envDict.map { "\($0.key)=\($0.value)" }

            let cArgs = args.map { strdup($0) } + [nil]
            let cEnv = envStrings.map { strdup($0) } + [nil]

            var pid: pid_t = 0
            let spawnStatus = posix_spawn(&pid, agyPath, &fileActions, &attr, cArgs, cEnv)

            for p in cArgs { if let p { free(p) } }
            for p in cEnv { if let p { free(p) } }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
            Darwin.close(outPipe[1])
            Darwin.close(errPipe[1])
            if devNull >= 0 { Darwin.close(devNull) }

            guard spawnStatus == 0, pid > 0 else {
                Darwin.close(outPipe[0])
                Darwin.close(errPipe[0])
                completion(nil, .failed("spawn \(spawnStatus)"))
                return
            }

            // All mutable state lives strictly on `self.ioQueue` — zero data races!
            var stdoutData = Data()
            var stderrData = Data()
            var aborting = false
            var delivered = false
            var timedOut = false
            var childExited = false
            var exitCode: Int32 = -1
            var outClosed = false
            var errClosed = false
            var outSource: DispatchSourceRead?
            var errSource: DispatchSourceRead?
            var procSource: DispatchSourceProcess?
            var timeoutTimer: DispatchSourceTimer?
            var killTimer: DispatchSourceTimer?
            var postExitGraceTimer: DispatchSourceTimer?

            let outFD = outPipe[0]
            let errFD = errPipe[0]

            func cancelTimer(_ t: inout DispatchSourceTimer?) {
                guard let timer = t else { return }
                t = nil
                timer.setEventHandler(handler: nil)
                timer.cancel()
            }

            func deliverResultIfReady() {
                guard !delivered, outClosed, errClosed, (childExited || aborting) else { return }
                delivered = true
                cancelTimer(&timeoutTimer)
                cancelTimer(&killTimer)
                cancelTimer(&postExitGraceTimer)
                if let ps = procSource {
                    procSource = nil
                    ps.setEventHandler(handler: nil)
                    ps.cancel()
                }
                outSource = nil
                errSource = nil

                if timedOut {
                    _ = Darwin.kill(-pid, SIGKILL)
                }
                if !childExited {
                    var wstatus: Int32 = 0
                    let r = Darwin.waitpid(pid, &wstatus, WNOHANG)
                    if r == pid || r < 0 {
                        childExited = true
                    }
                }

                if timedOut {
                    completion(nil, .timeout)
                    return
                }

                let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let combinedLow = (stderrStr + "\n" + stdoutStr).lowercased()

                if exitCode != 0 {
                    if combinedLow.contains("login") || combinedLow.contains("sign in") || combinedLow.contains("auth") || combinedLow.contains("unauthorized") {
                        completion(nil, .notSignedIn)
                    } else {
                        let brief = stderrStr.isEmpty ? "exit \(exitCode)" : String(stderrStr.prefix(80))
                        completion(nil, .failed(brief))
                    }
                    return
                }

                if let parsed = Self.parseUsageJSON(data: stdoutData) {
                    completion(parsed, .ready)
                } else if combinedLow.contains("login") || combinedLow.contains("sign in") || combinedLow.contains("authenticate") {
                    completion(nil, .notSignedIn)
                } else {
                    completion(nil, .failed("parse error"))
                }
            }

            func forceCloseAndFinish() {
                guard !aborting && !delivered else { return }
                aborting = true
                cancelTimer(&timeoutTimer)
                cancelTimer(&killTimer)
                cancelTimer(&postExitGraceTimer)
                if let ps = procSource {
                    procSource = nil
                    ps.setEventHandler(handler: nil)
                    ps.cancel()
                }
                if !outClosed {
                    outSource?.setEventHandler(handler: nil)
                    outSource?.cancel()
                }
                if !errClosed {
                    errSource?.setEventHandler(handler: nil)
                    errSource?.cancel()
                }
                // If both pipes are already closed, deliver immediately; otherwise the cancel handlers
                // will close the FDs first and then trigger deliverResultIfReady() deterministically.
                deliverResultIfReady()
            }

            func drainFD(_ fd: Int32, into buffer: inout Data) -> Bool {
                var chunk = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = Darwin.read(fd, &chunk, chunk.count)
                    if n > 0 {
                        if buffer.count < Self.maxOutputBytes {
                            let take = min(n, Self.maxOutputBytes - buffer.count)
                            buffer.append(contentsOf: chunk[0..<take])
                        }
                    } else if n == 0 {
                        return true // EOF
                    } else {
                        if errno == EAGAIN || errno == EWOULDBLOCK { return false }
                        return true
                    }
                }
            }

            // 1. Non-blocking stdout reader (clears handlers on cancel -> zero retain cycles)
            let os = DispatchSource.makeReadSource(fileDescriptor: outFD, queue: self.ioQueue)
            os.setEventHandler {
                if drainFD(outFD, into: &stdoutData) {
                    outSource?.setEventHandler(handler: nil)
                    outSource?.cancel()
                }
            }
            os.setCancelHandler {
                os.setEventHandler(handler: nil)
                os.setCancelHandler(handler: nil)
                outSource = nil
                if !outClosed {
                    outClosed = true
                    Darwin.close(outFD)
                    deliverResultIfReady()
                }
            }
            outSource = os

            // 2. Non-blocking stderr reader (clears handlers on cancel -> zero retain cycles)
            let es = DispatchSource.makeReadSource(fileDescriptor: errFD, queue: self.ioQueue)
            es.setEventHandler {
                if drainFD(errFD, into: &stderrData) {
                    errSource?.setEventHandler(handler: nil)
                    errSource?.cancel()
                }
            }
            es.setCancelHandler {
                es.setEventHandler(handler: nil)
                es.setCancelHandler(handler: nil)
                errSource = nil
                if !errClosed {
                    errClosed = true
                    Darwin.close(errFD)
                    deliverResultIfReady()
                }
            }
            errSource = es

            // 3. Process exit watcher (zero threads!)
            let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: self.ioQueue)
            ps.setEventHandler {
                var wstatus: Int32 = 0
                let reaped = Darwin.waitpid(pid, &wstatus, WNOHANG)
                if reaped == pid || reaped < 0 {
                    childExited = true
                    if (wstatus & 0x7F) == 0 {
                        exitCode = (wstatus >> 8) & 0xFF
                    } else {
                        exitCode = 128 + (wstatus & 0x7F)
                    }
                    // Final non-blocking drain
                    if !outClosed, drainFD(outFD, into: &stdoutData) {
                        outSource?.setEventHandler(handler: nil)
                        outSource?.cancel()
                    }
                    if !errClosed, drainFD(errFD, into: &stderrData) {
                        errSource?.setEventHandler(handler: nil)
                        errSource?.cancel()
                    }
                    deliverResultIfReady()

                    // If a stray grandchild inherited pipe write end, killpg & force-close after 0.35s grace
                    if !delivered && !aborting {
                        let gt = DispatchSource.makeTimerSource(queue: self.ioQueue)
                        gt.schedule(deadline: .now() + 0.35)
                        gt.setEventHandler {
                            if !delivered && !aborting {
                                _ = Darwin.kill(-pid, SIGKILL)
                                forceCloseAndFinish()
                            }
                        }
                        postExitGraceTimer = gt
                        gt.resume()
                    }
                }
            }
            procSource = ps

            // 4. Hard timeout -> SIGTERM whole process group -> 1.0s later SIGKILL whole process group!
            let tt = DispatchSource.makeTimerSource(queue: self.ioQueue)
            tt.schedule(deadline: .now() + self.timeoutSeconds)
            tt.setEventHandler {
                guard !delivered && !aborting else { return }
                timedOut = true
                _ = Darwin.kill(-pid, SIGTERM)
                let kt = DispatchSource.makeTimerSource(queue: self.ioQueue)
                kt.schedule(deadline: .now() + 1.0)
                kt.setEventHandler {
                    guard !delivered && !aborting else { return }
                    _ = Darwin.kill(-pid, SIGKILL)
                    if !childExited {
                        var ws: Int32 = 0
                        _ = Darwin.waitpid(pid, &ws, 0)
                        childExited = true
                    }
                    forceCloseAndFinish()
                }
                killTimer = kt
                kt.resume()
            }
            timeoutTimer = tt

            os.resume()
            es.resume()
            ps.resume()
            tt.resume()
        }
    }

    static func parseUsageJSON(data: Data) -> QuotaSnapshot? {
        let rawObj: Any?
        if let direct = try? JSONSerialization.jsonObject(with: data) {
            rawObj = direct
        } else if let text = String(data: data, encoding: .utf8),
                  let start = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}"),
                  start < end,
                  let sliced = String(text[start...end]).data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: sliced) {
            rawObj = parsed
        } else {
            return nil
        }

        guard let root = rawObj as? [String: Any],
              let command = root["command"] as? [String: Any],
              (command["name"] as? String) == "usage",
              let cmdData = command["data"] as? [String: Any],
              let rawGroups = cmdData["groups"] as? [[String: Any]] else {
            return nil
        }

        var groups: [QuotaGroup] = []
        for (idx, g) in rawGroups.prefix(16).enumerated() {
            let name = (g["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Group \(idx + 1)"
            let desc = (g["description"] as? String) ?? ""
            guard let rawBuckets = g["buckets"] as? [[String: Any]] else { continue }

            var buckets: [QuotaBucket] = []
            for b in rawBuckets.prefix(16) {
                guard let id = b["id"] as? String, !id.isEmpty else { continue }
                let bName = (b["name"] as? String) ?? id
                let window = (b["window"] as? String) ?? ""
                let frac = (b["remaining_fraction"] as? NSNumber)?.doubleValue
                let amt = (b["remaining_amount"] as? NSNumber)?.doubleValue
                let reset = b["reset_time"] as? String
                let disabled = (b["disabled"] as? Bool) ?? false

                if frac != nil || amt != nil || disabled {
                    let clampedFrac = frac.map { min(1.0, max(0.0, $0)) }
                    buckets.append(QuotaBucket(
                        id: id,
                        name: bName,
                        window: window,
                        remainingFraction: clampedFrac,
                        remainingAmount: amt,
                        resetTimeISO: reset,
                        disabled: disabled
                    ))
                }
            }
            guard !buckets.isEmpty else { continue }

            // Sort so weekly (7d) precedes 5h, matching native Antigravity /usage display order
            buckets.sort { a, b in
                if a.isWeekly != b.isWeekly { return a.isWeekly }
                if a.isFiveHour != b.isFiveHour { return a.isFiveHour }
                return a.id < b.id
            }

            let family = inferGroupFamily(name: name, desc: desc, buckets: buckets)
            let groupId = "\(family.rawValue)-\(idx)-\(name.lowercased())"
            groups.append(QuotaGroup(
                id: groupId,
                name: name,
                description: desc,
                family: family,
                buckets: buckets
            ))
        }

        guard !groups.isEmpty else { return nil }
        return QuotaSnapshot(fetchedAt: Date(), groups: groups, source: "cli")
    }

    private static func inferGroupFamily(name: String, desc: String, buckets: [QuotaBucket]) -> QuotaModelFamily {
        let joined = (name + " " + desc + " " + buckets.map(\.id).joined(separator: " ")).lowercased()
        if joined.contains("gemini") { return .gemini }
        if joined.contains("claude") || joined.contains("gpt") || joined.contains("3p-") { return .thirdParty }
        return .unknown
    }
}
