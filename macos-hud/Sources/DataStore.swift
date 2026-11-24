import Foundation
import SQLite3

struct SectionSample: Equatable {
    let name: String
    let bytes: Int
    let estTokens: Int
}

struct GenerationRecord: Equatable {
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

struct AnatomyItem: Identifiable, Equatable {
    let id: String
    let labelEn: String
    let labelZh: String
    let hexColor: UInt32
    let estTokens: Int
    let percentOfInput: Double
}

struct ContextAnatomy: Equatable {
    let totalInputTokens: Int
    let systemOverheadTokens: Int
    let systemOverheadPercent: Double
    let items: [AnatomyItem]
}

struct CacheDropEvent: Equatable {
    let callNumber: Int
    let prevRate: Int
    let currRate: Int
    let isModelSwitch: Bool
    let fromModel: String
    let toModel: String
}

struct CallRow: Identifiable, Equatable {
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

struct SubagentUsage: Identifiable, Equatable {
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

struct ConversationSummaryItem: Identifiable, Hashable, Equatable {
    let id: String
    let title: String
    let workspaceLabel: String
    let isRunning: Bool
    let activityMs: Double
    let childCount: Int
}

enum ContextLevel: Equatable {
    case normal, warning, critical
}

struct ConversationMetrics: Equatable {
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

struct HUDSnapshot: Equatable {
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

    static let initial = HUDSnapshot(
        conversationId: nil, title: "Token Lens", workspaceLabel: "", isRunning: false,
        syncSource: "auto", metrics: .empty, subagents: [], combinedTotalTokens: 0,
        combinedSubagentTokens: 0, recentConversations: []
    )
}

/// Strictly read-only, incremental, stat-cached Antigravity SQLite reader.
/// Opens SQLite only when `.db` or `.db-wal` changes, caps cache at 512 KiB, and closes
/// immediately (<1ms) so it never blocks Antigravity WAL checkpoints.
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

    private struct CachedConversationState {
        let fullFingerprint: String
        let mainDbFingerprint: String
        let maxIdx: Int
        let minIdx: Int
        let records: [GenerationRecord]
        let latestSections: (idx: Int, sections: [SectionSample])?
        let metrics: ConversationMetrics
    }

    private var summaryFingerprint = ""
    private var lastSummaryReadAt: TimeInterval = 0
    private var summariesById: [String: RawSummary] = [:]
    private var childrenByParent: [String: [RawSummary]] = [:]
    private var descendantsCache: [String: [RawSummary]] = [:]
    private var summaryList: [RawSummary] = []
    private var cachedRootCandidates: [ConversationSummaryItem] = []

    private var metricsCache: [String: CachedConversationState] = [:]
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

    // Cached passive DevToolsActivePort probe (avoids 1Hz HTTP spam & URLCache bloat)
    private var portFileFingerprint = ""
    private var cachedDevToolsPort: Int? = nil
    private var lastRouteCheckAt: TimeInterval = 0
    private var cachedRouteConvId: String? = nil
    private lazy var loopbackSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 0.2
        cfg.timeoutIntervalForResource = 0.25
        return URLSession(configuration: cfg)
    }()

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: .caseInsensitive
    )

    private static let routeUUIDRegex = try! NSRegularExpression(
        pattern: "(?:/c/|cascadeId=|conversationId=)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
        options: .caseInsensitive
    )

    init(baseDir: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resolvedBase = baseDir ?? home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        self.baseDir = resolvedBase
        self.conversationsDir = resolvedBase.appendingPathComponent("conversations", isDirectory: true)
        self.summariesDbPath = resolvedBase.appendingPathComponent("conversation_summaries.db").path
        self.devToolsPortFile = home
            .appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort")
            .path
    }

    private func singleFileFingerprint(_ path: String) -> String {
        var st = stat()
        if stat(path, &st) == 0 {
            return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        return "-"
    }

    private func statFingerprint(_ dbPath: String) -> (full: String, main: String) {
        let mainFp = singleFileFingerprint(dbPath)
        let walFp = singleFileFingerprint("\(dbPath)-wal")
        return ("\(mainFp)|\(walFp)", mainFp)
    }

    private func readDevToolsPortIfPresent() -> Int? {
        let fp = singleFileFingerprint(devToolsPortFile)
        if fp == "-" {
            portFileFingerprint = "-"
            cachedDevToolsPort = nil
            return nil
        }
        if fp == portFileFingerprint {
            return cachedDevToolsPort
        }
        portFileFingerprint = fp
        guard let raw = try? String(contentsOfFile: devToolsPortFile, encoding: .utf8),
              let firstLine = raw.split(whereSeparator: \.isNewline).first,
              let port = Int(firstLine.trimmingCharacters(in: .whitespaces)),
              port >= 1 && port <= 65535 else {
            cachedDevToolsPort = nil
            return nil
        }
        cachedDevToolsPort = port
        return port
    }

    /// Passive read-only HTTP GET to localhost /json/list when DevToolsActivePort exists.
    /// Throttled to <= once every 2.5s (unless forced on focus/open), race-free locked box, cancels on timeout.
    private func detectWindowConversationId(forceProbe: Bool) -> String? {
        guard let port = readDevToolsPortIfPresent() else {
            cachedRouteConvId = nil
            return nil
        }
        let now = Date().timeIntervalSinceReferenceDate
        if !forceProbe && (now - lastRouteCheckAt) < 2.5 {
            return cachedRouteConvId
        }
        lastRouteCheckAt = now

        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return nil }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: String? = nil
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.18)
        req.httpMethod = "GET"

        let task = loopbackSession.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            for target in list {
                let type = (target["type"] as? String) ?? ""
                let pageUrl = (target["url"] as? String) ?? ""
                guard type == "page", pageUrl.contains("127.0.0.1") || pageUrl.contains("localhost") else { continue }
                let ns = pageUrl as NSString
                if let match = Self.routeUUIDRegex.firstMatch(in: pageUrl, options: [], range: NSRange(location: 0, length: ns.length)),
                   match.numberOfRanges >= 2 {
                    let extracted = ns.substring(with: match.range(at: 1))
                    box.lock.lock()
                    box.value = extracted
                    box.lock.unlock()
                    return
                }
            }
        }
        task.resume()
        if sem.wait(timeout: .now() + 0.20) == .timedOut {
            task.cancel()
        }
        box.lock.lock()
        let result = box.value
        box.lock.unlock()
        cachedRouteConvId = result
        return result
    }

    private func isValidUUID(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: s.utf16.count)
        return Self.uuidRegex.firstMatch(in: s, options: [], range: range) != nil
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
        sqlite3_busy_timeout(handle, 50)
        sqlite3_exec(handle, "PRAGMA query_only = ON; PRAGMA cache_size = -512; PRAGMA mmap_size = 0;", nil, nil, nil)
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
        if isoMsCache.count > 1024 { isoMsCache.removeAll(keepingCapacity: true) }
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
        if workspaceLabelCache.count > 256 { workspaceLabelCache.removeAll(keepingCapacity: true) }
        workspaceLabelCache[jsonStr] = label
        return label
    }

    private func loadSummariesIfNeeded(force: Bool = false) {
        let now = Date().timeIntervalSinceReferenceDate
        if !force && !summaryList.isEmpty && (now - lastSummaryReadAt) < 2.5 { return }
        let fp = statFingerprint(summariesDbPath).full
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
            autoreleasepool {
                let id = colStr(0)
                guard isValidUUID(id) else { return }
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
        }

        list.sort { $0.lastModifiedMs > $1.lastModifiedMs }
        self.summaryFingerprint = fp
        self.summariesById = byId
        self.childrenByParent = children
        self.descendantsCache.removeAll(keepingCapacity: true)
        self.summaryList = list

        var rootsMap: [String: ConversationSummaryItem] = [:]
        for item in list {
            let rootId = resolveRootId(item.id)
            let rootMeta = byId[rootId] ?? item
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
                    childCount: (children[rootId] ?? []).count
                )
            }
        }
        self.cachedRootCandidates = Array(rootsMap.values.sorted { $0.activityMs > $1.activityMs }.prefix(24))
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
        if let cached = descendantsCache[rootId] { return cached }
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
        descendantsCache[rootId] = out
        return out
    }

    /// Reads conversation metrics incrementally with strict fallback to full scan on checkpoint/compaction.
    /// Preserves `latestSections` across incremental updates so Context Anatomy never disappears.
    func readConversationMetrics(_ id: String, forceFullScan: Bool = false) -> ConversationMetrics {
        let dbPath = conversationsDir.appendingPathComponent("\(id).db").path
        let fp = statFingerprint(dbPath)
        if fp.main == "-" {
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
        if !forceFullScan, let cached = metricsCache[id], cached.fullFingerprint == fp.full {
            return cached.metrics
        }

        guard let db = openReadOnly(dbPath) else {
            return metricsCache[id]?.metrics ?? .empty
        }
        defer { sqlite3_close(db) }

        // O(log n) B-tree boundary check instead of O(n) COUNT(*)
        var dbMaxIdx = -1
        var dbMinIdx = -1
        var metaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(idx), -1), COALESCE(MIN(idx), -1) FROM gen_metadata;", -1, &metaStmt, nil) == SQLITE_OK, let metaStmt {
            if sqlite3_step(metaStmt) == SQLITE_ROW {
                dbMaxIdx = Int(sqlite3_column_int64(metaStmt, 0))
                dbMinIdx = Int(sqlite3_column_int64(metaStmt, 1))
            }
            sqlite3_finalize(metaStmt)
        }

        if dbMaxIdx < 0 {
            let empty = ConversationMetrics.empty
            metricsCache[id] = CachedConversationState(
                fullFingerprint: fp.full, mainDbFingerprint: fp.main,
                maxIdx: -1, minIdx: -1, records: [], latestSections: nil, metrics: empty
            )
            return empty
        }

        // Incremental path: allowed ONLY when main `.db` file didn't rewrite/checkpoint AND indices grew monotonically.
        // Always re-reads the last 3 rows (idx >= cached.maxIdx - 2) to catch in-place streaming UPDATEs!
        var records: [GenerationRecord]
        var latestSections: (idx: Int, sections: [SectionSample])?
        let startIdx: Int
        if !forceFullScan,
           let cached = metricsCache[id],
           cached.mainDbFingerprint == fp.main,
           cached.maxIdx >= 0,
           dbMinIdx == cached.minIdx,
           dbMaxIdx >= cached.maxIdx {
            let tailStart = max(dbMinIdx, cached.maxIdx - 2)
            records = cached.records.filter { $0.index < tailStart }
            latestSections = cached.latestSections
            startIdx = tailStart
        } else {
            records = []
            latestSections = nil
            startIdx = Int.min
        }

        var stmt: OpaquePointer?
        let sql = startIdx == Int.min
            ? "SELECT idx, data FROM gen_metadata ORDER BY idx ASC;"
            : "SELECT idx, data FROM gen_metadata WHERE idx >= ? ORDER BY idx ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return metricsCache[id]?.metrics ?? .empty
        }
        defer { sqlite3_finalize(stmt) }
        if startIdx != Int.min {
            sqlite3_bind_int64(stmt, 1, Int64(startIdx))
        }

        // On full scan: parse sections on the last 4 rows (and if none had sections, latest non-empty survives in subsequent incremental ticks).
        // On incremental scan: parse sections on all newly fetched rows (usually 1-4 rows), never discarding previously captured non-empty sections!
        let sectionCutoffIdx = (startIdx == Int.min) ? max(0, dbMaxIdx - 3) : startIdx
        while sqlite3_step(stmt) == SQLITE_ROW {
            autoreleasepool {
                let idx = Int(sqlite3_column_int64(stmt, 0))
                let len = Int(sqlite3_column_bytes(stmt, 1))
                guard len > 0, let rawPtr = sqlite3_column_blob(stmt, 1) else { return }
                let buf = UnsafeRawBufferPointer(start: rawPtr, count: len)
                let parseSec = (idx >= sectionCutoffIdx)
                if let rec = ProtobufDecoder.decodeGeneration(idx: idx, buffer: buf, includeSections: parseSec) {
                    if !rec.sections.isEmpty {
                        latestSections = (idx, rec.sections)
                    }
                    // Strip heavy sections array from stored records to keep memory compact;
                    // we hold the single latest non-empty sections separately.
                    if rec.sections.isEmpty {
                        records.append(rec)
                    } else {
                        records.append(GenerationRecord(
                            index: rec.index, input: rec.input, output: rec.output, cached: rec.cached,
                            thinking: rec.thinking, response: rec.response, waitSeconds: rec.waitSeconds,
                            streamSeconds: rec.streamSeconds, contextLimit: rec.contextLimit,
                            modelDisplay: rec.modelDisplay, sections: []
                        ))
                    }
                }
            }
        }

        // If full scan's last 4 rows had no sections at all, probe backward for the latest row containing field 16 (one-time per DB)
        if startIdx == Int.min && latestSections == nil && dbMaxIdx > 3 {
            var revStmt: OpaquePointer?
            let revSql = "SELECT idx, data FROM gen_metadata WHERE idx < ? ORDER BY idx DESC LIMIT 12;"
            if sqlite3_prepare_v2(db, revSql, -1, &revStmt, nil) == SQLITE_OK, let revStmt {
                defer { sqlite3_finalize(revStmt) }
                sqlite3_bind_int64(revStmt, 1, Int64(sectionCutoffIdx))
                while sqlite3_step(revStmt) == SQLITE_ROW {
                    let idx = Int(sqlite3_column_int64(revStmt, 0))
                    let len = Int(sqlite3_column_bytes(revStmt, 1))
                    guard len > 0, let rawPtr = sqlite3_column_blob(revStmt, 1) else { continue }
                    let buf = UnsafeRawBufferPointer(start: rawPtr, count: len)
                    if let rec = ProtobufDecoder.decodeGeneration(idx: idx, buffer: buf, includeSections: true),
                       !rec.sections.isEmpty {
                        latestSections = (idx, rec.sections)
                        break
                    }
                }
            }
        }

        let summary = summarize(records, latestSections: latestSections?.sections)
        if metricsCache.count >= 12, metricsCache[id] == nil, let oldestKey = metricsCache.keys.first {
            metricsCache.removeValue(forKey: oldestKey)
        }
        metricsCache[id] = CachedConversationState(
            fullFingerprint: fp.full,
            mainDbFingerprint: fp.main,
            maxIdx: dbMaxIdx,
            minIdx: dbMinIdx,
            records: records,
            latestSections: latestSections,
            metrics: summary
        )
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

    private func computeAnatomy(latest: GenerationRecord, sections: [SectionSample]?) -> ContextAnatomy? {
        guard let sections, !sections.isEmpty else { return nil }
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
        for s in sections {
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

    private func summarize(_ records: [GenerationRecord], latestSections: [SectionSample]?) -> ConversationMetrics {
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
            anatomy: computeAnatomy(latest: last, sections: latestSections), cacheDrops: drops,
            runwayCallsLeft: runwayCalls, runwayGrowthPerCall: runwayGrowth,
            recentCalls: recent
        )
    }

    func fetchSnapshot(pinnedId: String?, forceRouteProbe: Bool = false) -> HUDSnapshot {
        loadSummariesIfNeeded(force: forceRouteProbe)

        var candidates = cachedRootCandidates

        let targetId: String?
        let syncSource: String
        if let pin = pinnedId, isValidUUID(pin) {
            targetId = pin
            syncSource = "pinned"
        } else if let winId = detectWindowConversationId(forceProbe: forceRouteProbe), isValidUUID(winId) {
            targetId = resolveRootId(winId)
            syncSource = "window"
        } else {
            for i in 0..<min(8, candidates.count) {
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
            targetId = candidates.first?.id
            syncSource = "auto"
        }

        guard let convId = targetId else {
            return HUDSnapshot(
                conversationId: nil, title: "Token Lens", workspaceLabel: "", isRunning: false,
                syncSource: syncSource, metrics: .empty, subagents: [], combinedTotalTokens: 0,
                combinedSubagentTokens: 0, recentConversations: candidates
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
            recentConversations: candidates
        )
    }
}
