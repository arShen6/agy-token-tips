import Foundation

/// Defensive zero-copy schema-less protobuf decoder for Antigravity `gen_metadata` records.
/// Reads only numeric telemetry, model names, and (on latest call only) section byte counts.
enum ProtobufDecoder {
    private static let maxReasonableTokens = 100_000_000
    private static let minContextLimit = 8_000
    private static let maxContextLimit = 4_000_000
    private static let maxDurationSeconds = 7_200.0

    enum FieldValue {
        case varint(UInt64)
        case bytes(Data)
        case fixed64(Data)
        case fixed32(Data)
    }

    struct Field {
        let number: Int
        let value: FieldValue
    }

    /// Zero-copy slice parser (uses `Data` SubSequence slices instead of copying 900KB buffers).
    static func parseFields(_ data: Data) throws -> [Field] {
        var result: [Field] = []
        result.reserveCapacity(16)
        var idx = data.startIndex
        let end = data.endIndex

        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 70 {
                guard idx < end else { throw NSError(domain: "PB", code: 1) }
                let byte = data[idx]
                idx = data.index(after: idx)
                value |= UInt64(byte & 0x7F) << shift
                if (byte & 0x80) == 0 { return value }
                shift += 7
            }
            throw NSError(domain: "PB", code: 2)
        }

        while idx < end {
            let tag = try readVarint()
            let fieldNum = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            guard fieldNum >= 1 && fieldNum <= 536_870_911 else {
                throw NSError(domain: "PB", code: 3)
            }
            switch wire {
            case 0:
                result.append(Field(number: fieldNum, value: .varint(try readVarint())))
            case 2:
                let lenU64 = try readVarint()
                let remaining = data.distance(from: idx, to: end)
                guard lenU64 <= UInt64(remaining) else { throw NSError(domain: "PB", code: 4) }
                let nextIdx = data.index(idx, offsetBy: Int(lenU64))
                result.append(Field(number: fieldNum, value: .bytes(data[idx..<nextIdx])))
                idx = nextIdx
            case 1:
                guard data.distance(from: idx, to: end) >= 8 else { throw NSError(domain: "PB", code: 5) }
                let nextIdx = data.index(idx, offsetBy: 8)
                result.append(Field(number: fieldNum, value: .fixed64(data[idx..<nextIdx])))
                idx = nextIdx
            case 5:
                guard data.distance(from: idx, to: end) >= 4 else { throw NSError(domain: "PB", code: 6) }
                let nextIdx = data.index(idx, offsetBy: 4)
                result.append(Field(number: fieldNum, value: .fixed32(data[idx..<nextIdx])))
                idx = nextIdx
            default:
                throw NSError(domain: "PB", code: 7)
            }
        }
        return result
    }

    private static func lastBytes(_ fields: [Field], _ num: Int) -> Data? {
        for f in fields.reversed() where f.number == num {
            if case .bytes(let d) = f.value { return d }
        }
        return nil
    }

    private static func childFields(_ fields: [Field], _ num: Int) -> [Field] {
        guard let d = lastBytes(fields, num), let parsed = try? parseFields(d) else { return [] }
        return parsed
    }

    private static func intField(_ fields: [Field], _ num: Int) -> Int {
        for f in fields.reversed() where f.number == num {
            if case .varint(let v) = f.value {
                return v <= UInt64(Int.max) ? Int(v) : Int.max
            }
        }
        return 0
    }

    private static func strField(_ fields: [Field], _ num: Int) -> String {
        guard let d = lastBytes(fields, num) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    private static func durationField(_ fields: [Field], _ num: Int) -> Double? {
        guard let d = lastBytes(fields, num), let sub = try? parseFields(d) else { return nil }
        let secs = intField(sub, 1)
        let nanos = intField(sub, 2)
        guard nanos >= 0 && nanos < 1_000_000_000 else { return nil }
        let total = Double(secs) + Double(nanos) / 1e9
        guard total.isFinite && total >= 0 && total <= maxDurationSeconds else { return nil }
        return total
    }

    private static func estimateSectionTokens(_ raw: Data) -> Int {
        var ascii = 0
        var nonAscii = 0
        raw.withUnsafeBytes { buf in
            for b in buf {
                if b < 128 { ascii += 1 } else { nonAscii += 1 }
            }
        }
        return Int((Double(ascii) / 4.0 + Double(nonAscii) / 2.2).rounded())
    }

    static func decodeGeneration(idx: Int, data: Data, includeSections: Bool = true) -> GenerationRecord? {
        guard !data.isEmpty, let root = try? parseFields(data) else { return nil }
        let call = childFields(root, 1)
        guard !call.isEmpty else { return nil }

        let usage = childFields(call, 4)
        let input = intField(usage, 2)
        let output = intField(usage, 3)
        let cached = intField(usage, 5)
        let thinking = intField(usage, 9)
        let response = intField(usage, 10)

        guard input >= 0 && input <= maxReasonableTokens,
              output >= 0 && output <= maxReasonableTokens,
              cached >= 0 && cached <= maxReasonableTokens,
              thinking >= 0 && thinking <= maxReasonableTokens,
              response >= 0 && response <= maxReasonableTokens else {
            return nil
        }

        let waitSeconds = durationField(call, 11)
        let streamSeconds = durationField(call, 12)

        let rawLimit = intField(childFields(childFields(call, 9), 10), 4)
        let contextLimit: Int? = (rawLimit >= minContextLimit && rawLimit <= maxContextLimit) ? rawLimit : nil

        let modelSlug = strField(call, 19)
        let modelDisplayRaw = strField(call, 21)
        let modelDisplay = !modelDisplayRaw.isEmpty ? modelDisplayRaw : (!modelSlug.isEmpty ? modelSlug : "Unknown Model")

        var sections: [SectionSample] = []
        if includeSections {
            for f in call where f.number == 16 {
                if case .bytes(let secData) = f.value, let sub = try? parseFields(secData) {
                    let name = strField(sub, 1).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let raw = lastBytes(sub, 2), !name.isEmpty, !raw.isEmpty {
                        sections.append(SectionSample(name: name, bytes: raw.count, estTokens: estimateSectionTokens(raw)))
                    }
                }
            }
        }

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
}
