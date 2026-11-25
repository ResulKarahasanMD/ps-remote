import Foundation

/// Minimal H.265 Annex B helpers for libchiaki's video buffers.
public enum HEVCAnnexB {
    public static let vps: UInt8 = 32
    public static let sps: UInt8 = 33
    public static let pps: UInt8 = 34
    public static let aud: UInt8 = 35

    /// NAL units without start codes; trailing zero bytes of each unit are removed
    /// (a NAL unit always ends in a non-zero rbsp_trailing_bits byte).
    public static func units(in buffer: UnsafeRawBufferPointer) -> [Data] {
        let bytes = buffer.bindMemory(to: UInt8.self)
        let count = bytes.count
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var i = 0
        while i + 2 < count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let codeStart = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((codeStart, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Data] = []
        for (index, start) in starts.enumerated() {
            var end = index + 1 < starts.count ? starts[index + 1].codeStart : count
            while end > start.payloadStart, bytes[end - 1] == 0 { end -= 1 }
            if end > start.payloadStart {
                units.append(Data(UnsafeBufferPointer(rebasing: bytes[start.payloadStart..<end])))
            }
        }
        return units
    }

    public static func type(of unit: Data) -> UInt8 {
        guard let first = unit.first else { return 0xFF }
        return (first >> 1) & 0x3F
    }

    public static func parameterSets(in units: [Data]) -> (vps: Data, sps: Data, pps: Data)? {
        guard let v = units.first(where: { type(of: $0) == vps }),
              let s = units.first(where: { type(of: $0) == sps }),
              let p = units.first(where: { type(of: $0) == pps })
        else { return nil }
        return (v, s, p)
    }

    /// Units that belong in a decoded sample: VCL (0–31) and SEI (39, 40).
    public static func isSampleUnit(_ unit: Data) -> Bool {
        let t = type(of: unit)
        return t < 32 || t == 39 || t == 40
    }

    public static func lengthPrefixed(_ units: [Data]) -> Data {
        var out = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}
