import Foundation
import SQLite3

struct SectionSample {
    let name: String
    let bytes: Int
    let estTokens: Int
}

struct GenerationRecord {
    let index: Int
    let input: Int
    let output: Int
    let cached: Int
    let thinking: Int
    let response: Int
    let waitSeconds: Double?
    let streamSeconds: Double?
    let contextLimit: Int?
    let modelDisplay: String
    let sections: [SectionSample]
}

struct AnatomyItem: Identifiable {
    let id: String
    let labelEn: String
    let labelZh: String
    let hexColor: UInt32
    let estTokens: Int
    let percentOfInput: Double
}

struct ContextAnatomy {
    let totalInputTokens: Int
    let systemOverheadTokens: Int
    let systemOverheadPercent: Double
    let items: [AnatomyItem]
}

struct CacheDropEvent {
    let callNumber: Int
    let prevRate: Int
    let currRate: Int
    let isModelSwitch: Bool
    let fromModel: String
    let toModel: String
}

struct CallRow: Identifiable {
    let id: Int
    let callNumber: Int
    let model: String
    let input: Int
    let cached: Int
    let cachePercent: Double?
    let output: Int
    let thinking: Int
    let response: Int
    let waitSeconds: Double?
    let speed: Double?
}

struct SubagentUsage: Identifiable {
    let id: String
    let name: String
    let model: String
    let calls: Int
    let input: Int
    let cached: Int
    let output: Int
    let totalTokens: Int
    let isRunning: Bool
}

struct ConversationSummaryItem: Identifiable, Hashable {
    let id: String
    let title: String
    let workspaceLabel: String
    let isRunning: Bool
    let activityMs: Double
    let childCount: Int
}

enum ContextLevel {
    case normal, warning, critical
}

struct ConversationMetrics {
    let hasData: Bool
    let status: String
    let model: String
    let speed: Double?
    let isStreamMode: Bool
    let endToEndSpeed: Double?
    let waitSeconds: Double?
    let streamSeconds: Double?
    let totalSeconds: Double?
    let latestOutput: Int
    let latestThinking: Int
    let latestResponse: Int
    let ctxUsed: Int
    let ctxLimit: Int?
    let ctxPercent: Double?
    let ctxLevel: ContextLevel
    let totalCalls: Int
    let totalInput: Int
    let totalCached: Int
    let totalOutput: Int
    let totalThinking: Int
    let totalResponse: Int
    let totalTokens: Int
    let cachePercent: Double?
    let anatomy: ContextAnatomy?
    let cacheDrops: [CacheDropEvent]
    let runwayCallsLeft: Int?
    let runwayGrowthPerCall: Int
    let recentCalls: [CallRow]

    static let empty = ConversationMetrics(
        hasData: false, status: "waiting", model: "—", speed: nil, isStreamMode: true,
        endToEndSpeed: nil, waitSeconds: nil, streamSeconds: nil, totalSeconds: nil,
        latestOutput: 0, latestThinking: 0, latestResponse: 0,
        ctxUsed: 0, ctxLimit: nil, ctxPercent: nil, ctxLevel: .normal,
        totalCalls: 0, totalInput: 0, totalCached: 0, totalOutput: 0, totalThinking: 0, totalResponse: 0,
        totalTokens: 0, cachePercent: nil, anatomy: nil, cacheDrops: [],
        runwayCallsLeft: nil, runwayGrowthPerCall: 0, recentCalls: []
    )
}

struct HUDSnapshot {
    let conversationId: String?
    let title: String
    let workspaceLabel: String
    let isRunning: Bool
    let syncSource: String // "window" | "pinned" | "auto"
    let metrics: ConversationMetrics
    let subagents: [SubagentUsage]
    let combinedTotalTokens: Int
    let combinedSubagentTokens: Int
    let recentConversations: [ConversationSummaryItem]
    let updatedAt: Date

    static let initial = HUDSnapshot(
        conversationId: nil, title: "Token Lens", workspaceLabel: "", isRunning: false,
        syncSource: "auto", metrics: .empty, subagents: [], combinedTotalTokens: 0,
        combinedSubagentTokens: 0, recentConversations: [], updatedAt: Date()
    )
}

/// Strictly read-only, stat-cached Antigravity SQLite reader.
/// Opens SQLite only when `.db` or `.db-wal` changes, and closes immediately (<2ms) so
/// it never holds locks or interferes with Antigravity.
final class AntigravityDataStore: @unchecked Sendable {
    private let baseDir: URL
    private let conversationsDir: URL
    private let summariesDbPath: String
    private let devToolsPortFile: String

    private struct RawSummary {
        let id: String
        let title: String
        let workspaceLabel: String
        let isRunning: Bool
        let lastModifiedMs: Double
        let agentName: String
        let parentId: String
    }

    private var summaryFingerprint = ""
    private var lastSummaryReadAt: TimeInterval = 0
    private var summariesById: [String: RawSummary] = [:]
    private var childrenByParent: [String: [RawSummary]] = [:]
    private var summaryList: [RawSummary] = []

    private var metricsCache: [String: (fingerprint: String, metrics: ConversationMetrics)] = [:]
    private var isoMsCache: [String: Double] = [:]
    private var workspaceLabelCache: [String: String] = [:]
    private let isoFmtFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoFmtStd: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: .caseInsensitive
    )

    private static let routeUUIDRegex = try! NSRegularExpression(
        pattern: "(?:/c/|cascadeId=|conversationId=)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
        options: .caseInsensitive
    )

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseDir = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        self.conversationsDir = baseDir.appendingPathComponent("conversations", isDirectory: true)
        self.summariesDbPath = baseDir.appendingPathComponent("conversation_summaries.db").path
        self.devToolsPortFile = home
            .appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort")
            .path
    }

    /// Passive read-only HTTP GET to localhost /json/list when DevToolsActivePort exists.
    /// Zero WebSocket connection, zero script injection, zero DOM mutation; degrades silently if absent.
    private func detectWindowConversationId() -> String? {
        guard let raw = try? String(contentsOfFile: devToolsPortFile, encoding: .utf8),
              let firstLine = raw.split(whereSeparator: \.isNewline).first,
              let port = Int(firstLine.trimmingCharacters(in: .whitespaces)),
              port > 0 && port <= 65535,
              let url = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            return nil
        }

        let sem = DispatchSemaphore(value: 0)
        var foundId: String? = nil
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.2)
        req.httpMethod = "GET"

        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            // Prefer primary `page` target whose URL contains `/c/<uuid>`
            for target in list {
                let type = (target["type"] as? String) ?? ""
                let pageUrl = (target["url"] as? String) ?? ""
                guard type == "page", pageUrl.contains("127.0.0.1") || pageUrl.contains("localhost") else { continue }
                let ns = pageUrl as NSString
                if let match = Self.routeUUIDRegex.firstMatch(in: pageUrl, options: [], range: NSRange(location: 0, length: ns.length)),
                   match.numberOfRanges >= 2 {
                    foundId = ns.substring(with: match.range(at: 1))
                    return
                }
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 0.22)
        return foundId
    }

    private func isValidUUID(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: s.utf16.count)
        return Self.uuidRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    private func statFingerprint(_ dbPath: String) -> String {
        let paths = [dbPath, "\(dbPath)-wal"]
        return paths.map { p -> String in
            var st = stat()
            if stat(p, &st) == 0 {
                return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            }
            return "-"
        }.joined(separator: "|")
    }

    private func fileLiveMtimeMs(_ dbPath: String) -> Double {
        var best: Double = 0
        for p in [dbPath, "\(dbPath)-wal"] {
            var st = stat()
            if stat(p, &st) == 0 && st.st_size > 0 {
                let ms = Double(st.st_mtimespec.tv_sec) * 1000.0 + Double(st.st_mtimespec.tv_nsec) / 1e6
                if ms > best { best = ms }
            }
        }
        return best
    }

    private func openReadOnly(_ path: String) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(handle, 60)
        sqlite3_exec(handle, "PRAGMA query_only = ON;", nil, nil, nil)
        return handle
    }

    private func parseIsoMs(_ raw: String) -> Double {
        if raw.isEmpty { return 0 }
        if let hit = isoMsCache[raw] { return hit }
        let normalized = raw.contains("T") ? raw : raw.replacingOccurrences(of: " ", with: "T")
        let ms: Double
        if let d = isoFmtFrac.date(from: normalized) {
            ms = d.timeIntervalSince1970 * 1000.0
        } else if let d = isoFmtStd.date(from: normalized) {
            ms = d.timeIntervalSince1970 * 1000.0
        } else {
            ms = 0
        }
        if isoMsCache.count > 2048 { isoMsCache.removeAll(keepingCapacity: true) }
        isoMsCache[raw] = ms
        return ms
    }

    private func parseWorkspaceLabel(_ jsonStr: String) -> String {
        if jsonStr.isEmpty { return "" }
        if let hit = workspaceLabelCache[jsonStr] { return hit }
        let label: String
        if let data = jsonStr.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
           let first = arr.first {
            let cleaned = first.replacingOccurrences(of: "file://", with: "")
            label = URL(fileURLWithPath: cleaned).lastPathComponent
        } else {
            label = ""
        }
        if workspaceLabelCache.count > 512 { workspaceLabelCache.removeAll(keepingCapacity: true) }
        workspaceLabelCache[jsonStr] = label
        return label
    }

    private func loadSummariesIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate
        // Avoid full summary scans more than once per 2.5s while WAL streams continuously
        if !summaryList.isEmpty && (now - lastSummaryReadAt) < 2.5 { return }
        let fp = statFingerprint(summariesDbPath)
        if fp.hasPrefix("-|") || fp == summaryFingerprint { return }
        lastSummaryReadAt = now
        guard let db = openReadOnly(summariesDbPath) else { return }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT conversation_id, title, last_modified_time, workspace_uris, status, agent_name, parent_conversation_id
        FROM conversation_summaries;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        var byId: [String: RawSummary] = [:]
        var children: [String: [RawSummary]] = [:]
        var list: [RawSummary] = []

        func colStr(_ idx: Int32) -> String {
            guard let ptr = sqlite3_column_text(stmt, idx) else { return "" }
            return String(cString: ptr)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = colStr(0)
            guard isValidUUID(id) else { continue }
            let title = colStr(1).trimmingCharacters(in: .whitespacesAndNewlines)
            let lm = parseIsoMs(colStr(2))
            let ws = parseWorkspaceLabel(colStr(3))
            let running = colStr(4) == "CASCADE_RUN_STATUS_RUNNING"
            let agentName = colStr(5).trimmingCharacters(in: .whitespacesAndNewlines)
            let parentRaw = colStr(6)
            let parentId = isValidUUID(parentRaw) ? parentRaw : ""

            let item = RawSummary(
                id: id, title: title, workspaceLabel: ws,
                isRunning: running, lastModifiedMs: lm,
                agentName: agentName, parentId: parentId
            )
            byId[id] = item
            list.append(item)
            if !parentId.isEmpty {
                children[parentId, default: []].append(item)
            }
        }

        list.sort { $0.lastModifiedMs > $1.lastModifiedMs }
        self.summaryFingerprint = fp
        self.summariesById = byId
        self.childrenByParent = children
        self.summaryList = list
    }

    private func resolveRootId(_ id: String) -> String {
        var cur = id
        var seen = Set<String>()
        while !seen.contains(cur) {
            seen.insert(cur)
            guard let meta = summariesById[cur], !meta.parentId.isEmpty else { return cur }
            cur = meta.parentId
        }
        return id
    }

    private func collectDescendants(_ rootId: String) -> [RawSummary] {
        var out: [RawSummary] = []
        var queue = childrenByParent[rootId] ?? []
        var seen: Set<String> = [rootId]
        while !queue.isEmpty && out.count < 48 {
            let child = queue.removeFirst()
            if seen.contains(child.id) { continue }
            seen.insert(child.id)
            out.append(child)
            if let grand = childrenByParent[child.id] {
                queue.append(contentsOf: grand)
            }
        }
        return out
    }

    private func readConversationMetrics(_ id: String) -> ConversationMetrics {
        let dbPath = conversationsDir.appendingPathComponent("\(id).db").path
        let fp = statFingerprint(dbPath)
        if fp.hasPrefix("-|") {
            return ConversationMetrics(
                hasData: false, status: "missing", model: "—", speed: nil, isStreamMode: true,
                endToEndSpeed: nil, waitSeconds: nil, streamSeconds: nil, totalSeconds: nil,
                latestOutput: 0, latestThinking: 0, latestResponse: 0,
                ctxUsed: 0, ctxLimit: nil, ctxPercent: nil, ctxLevel: .normal,
                totalCalls: 0, totalInput: 0, totalCached: 0, totalOutput: 0, totalThinking: 0, totalResponse: 0,
                totalTokens: 0, cachePercent: nil, anatomy: nil, cacheDrops: [],
                runwayCallsLeft: nil, runwayGrowthPerCall: 0, recentCalls: []
            )
        }
        if let cached = metricsCache[id], cached.fingerprint == fp {
            return cached.metrics
        }

        guard let db = openReadOnly(dbPath) else {
            return metricsCache[id]?.metrics ?? .empty
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT idx, data FROM gen_metadata ORDER BY idx ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return metricsCache[id]?.metrics ?? .empty
        }
        defer { sqlite3_finalize(stmt) }

        var records: [GenerationRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                let idx = Int(sqlite3_column_int64(stmt, 0))
                let len = Int(sqlite3_column_bytes(stmt, 1))
                if len > 0, let rawPtr = sqlite3_column_blob(stmt, 1) {
                    let data = Data(bytes: rawPtr, count: len)
                    if let rec = ProtobufDecoder.decodeGeneration(idx: idx, data: data) {
                        records.append(rec)
                    }
                }
            }
        }

        let summary = summarize(records)
        if metricsCache.count > 16 {
            metricsCache.removeValue(forKey: metricsCache.keys.first!)
        }
        metricsCache[id] = (fp, summary)
        return summary
    }

    private func computeSpeed(_ c: GenerationRecord) -> (speed: Double?, isStream: Bool, e2e: Double?, total: Double?) {
        let elapsed: Double? = (c.waitSeconds != nil && c.streamSeconds != nil) ? (c.waitSeconds! + c.streamSeconds!) : nil
        let streaming: Double? = (c.streamSeconds ?? 0) > 0 ? Double(c.output) / c.streamSeconds! : nil
        let e2e: Double? = (elapsed ?? 0) > 0 ? Double(c.output) / elapsed! : nil
        let plausible: Bool
        if let ss = c.streamSeconds, let sp = streaming, ss >= 0.5, sp > 0, sp <= 600 {
            if let el = elapsed, el > 0 {
                plausible = (ss / el >= 0.15) || (ss >= 2.0 && sp <= 250)
            } else {
                plausible = true
            }
        } else {
            plausible = false
        }
        return (plausible ? streaming : e2e, plausible, e2e, elapsed)
    }

    private func computeAnatomy(_ calls: [GenerationRecord]) -> ContextAnatomy? {
        guard let secCall = calls.last(where: { !$0.sections.isEmpty }),
              let latest = calls.last else { return nil }
        let totalIn = latest.input + latest.cached
        guard totalIn > 0 else { return nil }

        let coreSet: Set<String> = [
            "identity", "guidelines", "work_efficiently", "communication_style",
            "messaging", "user_information", "conversation_transcript"
        ]
        let metaMap: [String: (en: String, zh: String, hex: UInt32)] = [
            "skills": ("Skills", "Skills 技能", 0x38BDF8),
            "subagents": ("Subagents", "Subagents 子代理", 0xA78BFA),
            "user_rules": ("User Rules", "用户规则", 0xF59E0B),
            "featured_plugins": ("Plugins Catalog", "插件推荐", 0xFB7185),
            "artifacts": ("Artifacts", "Artifacts", 0x2DD4BF),
            "mcp_servers": ("MCP", "MCP 服务", 0xF97316),
            "slash_commands": ("Slash Cmds", "斜杠命令", 0x818CF8),
            "core_prompt": ("Core System", "系统核心", 0x94A3B8),
            "conversation": ("Chat & Tools", "对话与工具", 0x34D399)
        ]

        var buckets: [String: Int] = [:]
        var rawSum = 0
        for s in secCall.sections {
            let k = coreSet.contains(s.name) ? "core_prompt" : s.name
            buckets[k, default: 0] += s.estTokens
            rawSum += s.estTokens
        }
        let scale = Double(rawSum) > Double(totalIn) * 0.95 ? (Double(totalIn) * 0.95) / Double(rawSum) : 1.0

        var items: [AnatomyItem] = []
        var sysSum = 0
        for (k, rawTok) in buckets {
            let tok = Int((Double(rawTok) * scale).rounded())
            sysSum += tok
            let m = metaMap[k] ?? (k, k, 0x64748B)
            items.append(AnatomyItem(
                id: k, labelEn: m.en, labelZh: m.zh, hexColor: m.hex,
                estTokens: tok, percentOfInput: 100.0 * Double(tok) / Double(totalIn)
            ))
        }
        items.sort { $0.estTokens > $1.estTokens }
        let histTok = max(0, totalIn - sysSum)
        let cm = metaMap["conversation"]!
        items.insert(AnatomyItem(
            id: "conversation", labelEn: cm.en, labelZh: cm.zh, hexColor: cm.hex,
            estTokens: histTok, percentOfInput: 100.0 * Double(histTok) / Double(totalIn)
        ), at: 0)

        return ContextAnatomy(
            totalInputTokens: totalIn,
            systemOverheadTokens: sysSum,
            systemOverheadPercent: 100.0 * Double(sysSum) / Double(totalIn),
            items: items
        )
    }

    private func summarize(_ records: [GenerationRecord]) -> ConversationMetrics {
        let calls = records.filter { $0.input > 0 || $0.cached > 0 || $0.output > 0 }
        guard let last = calls.last else { return .empty }

        let sp = computeSpeed(last)
        let used = last.input + last.cached
        let limit = last.contextLimit
        let ctxPct: Double? = limit.map { 100.0 * Double(used) / Double($0) }
        let level: ContextLevel
        if let p = ctxPct {
            level = p >= 90 ? .critical : (p >= 75 ? .warning : .normal)
        } else {
            level = .normal
        }

        var tIn = 0, tCached = 0, tOut = 0, tThink = 0, tResp = 0
        for c in calls {
            tIn += c.input; tCached += c.cached; tOut += c.output; tThink += c.thinking; tResp += c.response
        }
        let cachePct: Double? = (tIn + tCached) > 0 ? 100.0 * Double(tCached) / Double(tIn + tCached) : nil

        // Cache drops
        var drops: [CacheDropEvent] = []
        if calls.count >= 2 {
            for i in 1..<calls.count {
                let prev = calls[i - 1], curr = calls[i]
                let pTot = prev.input + prev.cached, cTot = curr.input + curr.cached
                if pTot < 8_000 || cTot < 8_000 { continue }
                let pRate = Double(prev.cached) / Double(pTot)
                let cRate = Double(curr.cached) / Double(cTot)
                if pRate >= 0.5 && cRate <= 0.15 {
                    drops.append(CacheDropEvent(
                        callNumber: i + 1,
                        prevRate: Int((pRate * 100).rounded()),
                        currRate: Int((cRate * 100).rounded()),
                        isModelSwitch: prev.modelDisplay != curr.modelDisplay,
                        fromModel: prev.modelDisplay,
                        toModel: curr.modelDisplay
                    ))
                }
            }
        }

        // Runway
        var runwayCalls: Int? = nil
        var runwayGrowth = 0
        if let lim = limit, calls.count >= 3 {
            let slice = Array(calls.suffix(min(6, calls.count)))
            let firstU = slice.first!.input + slice.first!.cached
            let lastU = slice.last!.input + slice.last!.cached
            let avg = Double(lastU - firstU) / Double(slice.count - 1)
            let target = Double(lim) * 0.9
            runwayGrowth = Int(avg.rounded())
            if Double(lastU) >= target {
                runwayCalls = 0
            } else if avg > 200 {
                runwayCalls = max(1, Int(floor((target - Double(lastU)) / avg)))
            }
        }

        let recent: [CallRow] = calls.suffix(8).enumerated().reversed().map { offset, c in
            let callNo = calls.count - min(8, calls.count) + offset + 1
            let s = computeSpeed(c)
            let totIn = c.input + c.cached
            return CallRow(
                id: c.index,
                callNumber: callNo,
                model: c.modelDisplay,
                input: c.input,
                cached: c.cached,
                cachePercent: totIn > 0 ? 100.0 * Double(c.cached) / Double(totIn) : nil,
                output: c.output,
                thinking: c.thinking,
                response: c.response,
                waitSeconds: c.waitSeconds,
                speed: s.speed
            )
        }

        return ConversationMetrics(
            hasData: true, status: "ready", model: last.modelDisplay,
            speed: sp.speed, isStreamMode: sp.isStream, endToEndSpeed: sp.e2e,
            waitSeconds: last.waitSeconds, streamSeconds: last.streamSeconds, totalSeconds: sp.total,
            latestOutput: last.output, latestThinking: last.thinking, latestResponse: last.response,
            ctxUsed: used, ctxLimit: limit, ctxPercent: ctxPct, ctxLevel: level,
            totalCalls: calls.count, totalInput: tIn, totalCached: tCached,
            totalOutput: tOut, totalThinking: tThink, totalResponse: tResp,
            totalTokens: tIn + tCached + tOut, cachePercent: cachePct,
            anatomy: computeAnatomy(calls), cacheDrops: drops,
            runwayCallsLeft: runwayCalls, runwayGrowthPerCall: runwayGrowth,
            recentCalls: recent
        )
    }

    func fetchSnapshot(pinnedId: String?) -> HUDSnapshot {
        loadSummariesIfNeeded()

        var rootsMap: [String: ConversationSummaryItem] = [:]
        for item in summaryList {
            let rootId = resolveRootId(item.id)
            let rootMeta = summariesById[rootId] ?? item
            let actMs = max(item.lastModifiedMs, rootMeta.lastModifiedMs)
            let running = item.isRunning || rootMeta.isRunning
            if let existing = rootsMap[rootId] {
                rootsMap[rootId] = ConversationSummaryItem(
                    id: rootId,
                    title: existing.title,
                    workspaceLabel: existing.workspaceLabel,
                    isRunning: existing.isRunning || running,
                    activityMs: max(existing.activityMs, actMs),
                    childCount: existing.childCount
                )
            } else {
                let title = !rootMeta.title.isEmpty ? rootMeta.title : "Conversation \(rootId.prefix(8))"
                rootsMap[rootId] = ConversationSummaryItem(
                    id: rootId,
                    title: title,
                    workspaceLabel: rootMeta.workspaceLabel,
                    isRunning: running,
                    activityMs: actMs,
                    childCount: (childrenByParent[rootId] ?? []).count
                )
            }
        }

        var candidates = Array(rootsMap.values.sorted { $0.activityMs > $1.activityMs }.prefix(24))
        // Refine with real .db-wal mtime so live replies jump to #1 immediately
        for i in 0..<candidates.count {
            let cid = candidates[i].id
            var bestMs = max(candidates[i].activityMs, fileLiveMtimeMs(conversationsDir.appendingPathComponent("\(cid).db").path))
            for ch in childrenByParent[cid] ?? [] {
                bestMs = max(bestMs, fileLiveMtimeMs(conversationsDir.appendingPathComponent("\(ch.id).db").path))
            }
            if bestMs > candidates[i].activityMs {
                let c = candidates[i]
                candidates[i] = ConversationSummaryItem(
                    id: c.id, title: c.title, workspaceLabel: c.workspaceLabel,
                    isRunning: c.isRunning, activityMs: bestMs, childCount: c.childCount
                )
            }
        }
        candidates.sort { $0.activityMs > $1.activityMs }

        let targetId: String?
        let syncSource: String
        if let pin = pinnedId, isValidUUID(pin) {
            targetId = pin
            syncSource = "pinned"
        } else if let winId = detectWindowConversationId(), isValidUUID(winId) {
            targetId = resolveRootId(winId)
            syncSource = "window"
        } else {
            targetId = candidates.first?.id
            syncSource = "auto"
        }

        guard let convId = targetId else {
            return HUDSnapshot(
                conversationId: nil, title: "Token Lens", workspaceLabel: "", isRunning: false,
                syncSource: syncSource, metrics: .empty, subagents: [], combinedTotalTokens: 0,
                combinedSubagentTokens: 0, recentConversations: candidates, updatedAt: Date()
            )
        }

        let meta = summariesById[convId]
        let metrics = readConversationMetrics(convId)
        let title = (meta != nil && !meta!.title.isEmpty) ? meta!.title : "Conversation \(convId.prefix(8))"

        var subagents: [SubagentUsage] = []
        var subTokens = 0
        for ch in collectDescendants(convId) {
            let cm = readConversationMetrics(ch.id)
            guard cm.hasData else { continue }
            let name = !ch.agentName.isEmpty ? ch.agentName : (!ch.title.isEmpty ? ch.title : "Subagent \(ch.id.prefix(6))")
            subagents.append(SubagentUsage(
                id: ch.id, name: name, model: cm.model, calls: cm.totalCalls,
                input: cm.totalInput, cached: cm.totalCached, output: cm.totalOutput,
                totalTokens: cm.totalTokens, isRunning: ch.isRunning
            ))
            subTokens += cm.totalTokens
        }
        subagents.sort { $0.totalTokens > $1.totalTokens }

        return HUDSnapshot(
            conversationId: convId,
            title: title,
            workspaceLabel: meta?.workspaceLabel ?? "",
            isRunning: meta?.isRunning ?? false,
            syncSource: syncSource,
            metrics: metrics,
            subagents: subagents,
            combinedTotalTokens: metrics.totalTokens + subTokens,
            combinedSubagentTokens: subTokens,
            recentConversations: candidates,
            updatedAt: Date()
        )
    }
}
