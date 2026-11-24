import Foundation

/// Zero-allocation streaming protobuf decoder operating directly on `UnsafeRawBufferPointer`.
/// Skips unknown wire fields by advancing cursor offset without allocating `[Field]` arrays
/// or retaining any pointers to SQLite column memory past the call.
enum ProtobufDecoder {
    private static let maxReasonableTokens = 100_000_000
    private static let minContextLimit = 8_000
    private static let maxContextLimit = 4_000_000
    private static let maxDurationSeconds = 7_200.0

    private struct Cursor {
        let base: UnsafeRawPointer
        let count: Int
        var offset: Int = 0

        @inline(__always)
        mutating func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 70 {
                guard offset < count else { return nil }
                let byte = base.load(fromByteOffset: offset, as: UInt8.self)
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if (byte & 0x80) == 0 { return value }
                shift += 7
            }
            return nil
        }

        @inline(__always)
        mutating func readBytesSlice() -> UnsafeRawBufferPointer? {
            guard let lenU64 = readVarint(), lenU64 <= UInt64(count - offset) else { return nil }
            let len = Int(lenU64)
            let slice = UnsafeRawBufferPointer(start: base.advanced(by: offset), count: len)
            offset += len
            return slice
        }

        @inline(__always)
        mutating func skip(wire: Int) -> Bool {
            switch wire {
            case 0:
                return readVarint() != nil
            case 1:
                guard offset + 8 <= count else { return false }
                offset += 8
                return true
            case 2:
                guard let lenU64 = readVarint(), lenU64 <= UInt64(count - offset) else { return false }
                offset += Int(lenU64)
                return true
            case 5:
                guard offset + 4 <= count else { return false }
                offset += 4
                return true
            default:
                return false
            }
        }
    }

    @inline(__always)
    private static func copyUTF8(_ slice: UnsafeRawBufferPointer) -> String {
        guard let base = slice.baseAddress, slice.count > 0 else { return "" }
        let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: slice.count)
        return String(decoding: buf, as: UTF8.self)
    }

    @inline(__always)
    private static func clampInt(_ v: UInt64) -> Int {
        v <= UInt64(Int.max) ? Int(v) : Int.max
    }

    private static func estimateSectionTokens(_ slice: UnsafeRawBufferPointer) -> Int {
        var ascii = 0
        var nonAscii = 0
        for b in slice {
            if b < 128 { ascii += 1 } else { nonAscii += 1 }
        }
        return Int((Double(ascii) / 4.0 + Double(nonAscii) / 2.2).rounded())
    }

    private static func parseDuration(_ slice: UnsafeRawBufferPointer) -> Double? {
        guard let base = slice.baseAddress, slice.count > 0 else { return nil }
        var cur = Cursor(base: base, count: slice.count)
        var secs = 0
        var nanos = 0
        while cur.offset < cur.count {
            guard let tag = cur.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if wire == 0, field == 1 {
                guard let v = cur.readVarint() else { return nil }
                secs = clampInt(v)
            } else if wire == 0, field == 2 {
                guard let v = cur.readVarint() else { return nil }
                nanos = clampInt(v)
            } else {
                guard cur.skip(wire: wire) else { return nil }
            }
        }
        guard nanos >= 0 && nanos < 1_000_000_000 else { return nil }
        let total = Double(secs) + Double(nanos) / 1e9
        guard total.isFinite && total >= 0 && total <= maxDurationSeconds else { return nil }
        return total
    }

    private static func parseContextLimit(_ field9: UnsafeRawBufferPointer) -> Int? {
        guard let base9 = field9.baseAddress, field9.count > 0 else { return nil }
        var cur9 = Cursor(base: base9, count: field9.count)
        var lastField10: UnsafeRawBufferPointer? = nil
        while cur9.offset < cur9.count {
            guard let tag = cur9.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if wire == 2, field == 10 {
                guard let s = cur9.readBytesSlice() else { return nil }
                lastField10 = s
            } else {
                guard cur9.skip(wire: wire) else { return nil }
            }
        }
        guard let f10 = lastField10, let base10 = f10.baseAddress, f10.count > 0 else { return nil }
        var cur10 = Cursor(base: base10, count: f10.count)
        var rawLimit = 0
        while cur10.offset < cur10.count {
            guard let tag = cur10.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if wire == 0, field == 4 {
                guard let v = cur10.readVarint() else { return nil }
                rawLimit = clampInt(v)
            } else {
                guard cur10.skip(wire: wire) else { return nil }
            }
        }
        return (rawLimit >= minContextLimit && rawLimit <= maxContextLimit) ? rawLimit : nil
    }

    private static func parseSection(_ slice: UnsafeRawBufferPointer) -> SectionSample? {
        guard let base = slice.baseAddress, slice.count > 0 else { return nil }
        var cur = Cursor(base: base, count: slice.count)
        var nameSlice: UnsafeRawBufferPointer? = nil
        var rawSlice: UnsafeRawBufferPointer? = nil
        while cur.offset < cur.count {
            guard let tag = cur.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if wire == 2, field == 1 {
                guard let s = cur.readBytesSlice() else { return nil }
                nameSlice = s
            } else if wire == 2, field == 2 {
                guard let s = cur.readBytesSlice() else { return nil }
                rawSlice = s
            } else {
                guard cur.skip(wire: wire) else { return nil }
            }
        }
        guard let ns = nameSlice, let rs = rawSlice, rs.count > 0 else { return nil }
        let name = copyUTF8(ns).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return SectionSample(name: name, bytes: rs.count, estTokens: estimateSectionTokens(rs))
    }

    /// Streams directly over a SQLite blob buffer (`UnsafeRawBufferPointer`), copying out only
    /// scalar values and short model/section strings. Zero dangling references possible.
    static func decodeGeneration(idx: Int, buffer: UnsafeRawBufferPointer, includeSections: Bool = true) -> GenerationRecord? {
        guard let rootBase = buffer.baseAddress, buffer.count > 0 else { return nil }
        var root = Cursor(base: rootBase, count: buffer.count)
        var callSlice: UnsafeRawBufferPointer? = nil
        while root.offset < root.count {
            guard let tag = root.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if wire == 2, field == 1 {
                guard let s = root.readBytesSlice() else { return nil }
                callSlice = s
            } else {
                guard root.skip(wire: wire) else { return nil }
            }
        }
        guard let call = callSlice, let callBase = call.baseAddress, call.count > 0 else { return nil }

        var cur = Cursor(base: callBase, count: call.count)
        var usageSlice: UnsafeRawBufferPointer? = nil
        var waitSlice: UnsafeRawBufferPointer? = nil
        var streamSlice: UnsafeRawBufferPointer? = nil
        var field9Slice: UnsafeRawBufferPointer? = nil
        var slugSlice: UnsafeRawBufferPointer? = nil
        var displaySlice: UnsafeRawBufferPointer? = nil
        var sections: [SectionSample] = []

        while cur.offset < cur.count {
            guard let tag = cur.readVarint() else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if wire == 2 {
                switch field {
                case 4:
                    guard let s = cur.readBytesSlice() else { return nil }
                    usageSlice = s
                case 9:
                    guard let s = cur.readBytesSlice() else { return nil }
                    field9Slice = s
                case 11:
                    guard let s = cur.readBytesSlice() else { return nil }
                    waitSlice = s
                case 12:
                    guard let s = cur.readBytesSlice() else { return nil }
                    streamSlice = s
                case 16:
                    guard let s = cur.readBytesSlice() else { return nil }
                    if includeSections, let sample = parseSection(s) {
                        sections.append(sample)
                    }
                case 19:
                    guard let s = cur.readBytesSlice() else { return nil }
                    slugSlice = s
                case 21:
                    guard let s = cur.readBytesSlice() else { return nil }
                    displaySlice = s
                default:
                    guard cur.skip(wire: wire) else { return nil }
                }
            } else {
                guard cur.skip(wire: wire) else { return nil }
            }
        }

        var input = 0, output = 0, cached = 0, thinking = 0, response = 0
        if let u = usageSlice, let uBase = u.baseAddress, u.count > 0 {
            var uCur = Cursor(base: uBase, count: u.count)
            while uCur.offset < uCur.count {
                guard let tag = uCur.readVarint() else { break }
                let field = Int(tag >> 3)
                let wire = Int(tag & 0x7)
                if wire == 0 {
                    guard let v = uCur.readVarint() else { break }
                    switch field {
                    case 2: input = clampInt(v)
                    case 3: output = clampInt(v)
                    case 5: cached = clampInt(v)
                    case 9: thinking = clampInt(v)
                    case 10: response = clampInt(v)
                    default: break
                    }
                } else {
                    guard uCur.skip(wire: wire) else { break }
                }
            }
        }

        guard input >= 0 && input <= maxReasonableTokens,
              output >= 0 && output <= maxReasonableTokens,
              cached >= 0 && cached <= maxReasonableTokens,
              thinking >= 0 && thinking <= maxReasonableTokens,
              response >= 0 && response <= maxReasonableTokens else {
            return nil
        }

        let waitSeconds = waitSlice.flatMap { parseDuration($0) }
        let streamSeconds = streamSlice.flatMap { parseDuration($0) }
        let contextLimit = field9Slice.flatMap { parseContextLimit($0) }
        let modelSlug = slugSlice.map { copyUTF8($0) } ?? ""
        let modelDisplayRaw = displaySlice.map { copyUTF8($0) } ?? ""
        let modelDisplay = !modelDisplayRaw.isEmpty ? modelDisplayRaw : (!modelSlug.isEmpty ? modelSlug : "Unknown Model")

        return GenerationRecord(
            index: idx,
            input: input,
            output: output,
            cached: cached,
            thinking: thinking,
            response: response,
            waitSeconds: waitSeconds,
            streamSeconds: streamSeconds,
            contextLimit: contextLimit,
            modelDisplay: modelDisplay,
            sections: sections
        )
    }

    static func decodeGeneration(idx: Int, data: Data, includeSections: Bool = true) -> GenerationRecord? {
        data.withUnsafeBytes { buf in
            decodeGeneration(idx: idx, buffer: buf, includeSections: includeSections)
        }
    }
}
