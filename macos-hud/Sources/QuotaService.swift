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
/// Zero turns, zero tokens, single-flight process execution, 20s timeout, disk-cached.
final class QuotaService: @unchecked Sendable {
    private let cacheURL: URL
    private let runnerQueue = DispatchQueue(label: "io.tokenlens.quota", qos: .utility)
    private let stateLock = NSLock()
    private var inFlight = false
    private var lastAttemptAt: Date = .distantPast
    private var consecutiveFailures = 0

    // Backoff schedule on failures: 60s, 120s, 300s, 600s
    private static let backoffSeconds: [TimeInterval] = [60, 120, 300, 600]

    init() {
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
        // Discard caches older than 24h so stale percentages never mislead
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
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/usr/bin/agy"
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let p = "\(dir)/agy"
                if !candidates.contains(p) { candidates.append(p) }
            }
        }
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
        let now = Date()
        stateLock.lock()
        if inFlight {
            stateLock.unlock()
            return
        }
        if force {
            // 8s debounce for manual clicks unless previous call failed
            if consecutiveFailures == 0 && now.timeIntervalSince(lastAttemptAt) < 8 {
                stateLock.unlock()
                return
            }
            consecutiveFailures = 0
        } else {
            // Respect cache freshness
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
            // Respect exponential backoff after failure
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

        runnerQueue.async { [weak self] in
            guard let self else { return }
            let (snapshot, state) = self.executeAgyUsage()
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

    private func executeAgyUsage() -> (QuotaSnapshot?, QuotaFetchState) {
        guard let agyPath = resolveAgyExecutable() else {
            return (nil, .cliMissing)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agyPath)
        proc.arguments = [
            "--settings",
            "{\"disableSlashCommands\":false,\"statusLine\":{\"enabled\":false},\"useG1Credits\":false}",
            "--output-format", "json",
            "-p", "/usage"
        ]

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let cur = env["PATH"], !cur.isEmpty {
            env["PATH"] = "\(extraPath):\(cur)"
        } else {
            env["PATH"] = extraPath
        }
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return (nil, .failed(error.localizedDescription))
        }

        // Read pipes concurrently so large buffers never deadlock waitUntilExit
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let doneSem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            proc.waitUntilExit()
            doneSem.signal()
        }

        let waitResult = doneSem.wait(timeout: .now() + 20.0)
        if waitResult == .timedOut {
            proc.terminate()
            _ = doneSem.wait(timeout: .now() + 1.0)
            return (nil, .timeout)
        }

        _ = group.wait(timeout: .now() + 2.0)

        let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stdoutStr = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combinedLow = (stderrStr + "\n" + stdoutStr).lowercased()

        if proc.terminationStatus != 0 {
            if combinedLow.contains("login") || combinedLow.contains("sign in") || combinedLow.contains("auth") || combinedLow.contains("unauthorized") {
                return (nil, .notSignedIn)
            }
            let brief = stderrStr.isEmpty ? "exit \(proc.terminationStatus)" : String(stderrStr.prefix(80))
            return (nil, .failed(brief))
        }

        if let parsed = Self.parseUsageJSON(data: stdoutData) {
            return (parsed, .ready)
        }

        if combinedLow.contains("login") || combinedLow.contains("sign in") || combinedLow.contains("authenticate") {
            return (nil, .notSignedIn)
        }
        return (nil, .failed("parse error"))
    }

    static func parseUsageJSON(data: Data) -> QuotaSnapshot? {
        // Tolerate any leading/trailing non-JSON log lines by slicing outermost `{ ... }`
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
