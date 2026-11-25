import Foundation
import Testing
@testable import MediaKit

@Suite struct HEVCAnnexBTests {
    /// NAL header bytes: type << 1 in the first byte, second byte 0x01 (layer 0, tid 1).
    static let vps = Data([0x40, 0x01, 0x0C, 0x01])
    static let sps = Data([0x42, 0x01, 0x01, 0x21])
    static let pps = Data([0x44, 0x01, 0xC1, 0x72])
    static let idr = Data([0x26, 0x01, 0xAF, 0x09, 0x40])   // type 19 (IDR_W_RADL)
    static let aud = Data([0x46, 0x01, 0x50])                // type 35
    static let sei = Data([0x4E, 0x01, 0x05, 0x10])          // type 39

    func withBuffer<T>(_ data: Data, _ body: (UnsafeRawBufferPointer) -> T) -> T {
        data.withUnsafeBytes(body)
    }

    @Test func splitsOnThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1]) + Self.vps + Data([0, 0, 1]) + Self.sps + Data([0, 0, 0, 1]) + Self.pps
        let units = withBuffer(stream) { HEVCAnnexB.units(in: $0) }
        #expect(units == [Self.vps, Self.sps, Self.pps])
        #expect(units.map(HEVCAnnexB.type(of:)) == [32, 33, 34])
    }

    @Test func stripsTrailingZeroBytesFromEachUnit() {
        // libchiaki pads the header buffer with zeros; trailing_zero_8bits may also precede a start code.
        let stream = Data([0, 0, 0, 1]) + Self.sps + Data([0, 0]) + Data([0, 0, 0, 1]) + Self.pps + Data(count: 64)
        let units = withBuffer(stream) { HEVCAnnexB.units(in: $0) }
        #expect(units == [Self.sps, Self.pps])
    }

    @Test func emptyOrStartCodeOnlyBufferHasNoUnits() {
        #expect(withBuffer(Data()) { HEVCAnnexB.units(in: $0) }.isEmpty)
        #expect(withBuffer(Data([0, 0, 0, 1])) { HEVCAnnexB.units(in: $0) }.isEmpty)
    }

    @Test func findsParameterSetsOnlyWhenAllThreeArePresent() {
        let sets = HEVCAnnexB.parameterSets(in: [Self.vps, Self.sps, Self.pps, Self.idr])
        #expect(sets?.vps == Self.vps)
        #expect(sets?.sps == Self.sps)
        #expect(sets?.pps == Self.pps)
        #expect(HEVCAnnexB.parameterSets(in: [Self.sps, Self.pps]) == nil)
    }

    @Test func sampleUnitsAreVCLAndSEIOnly() {
        #expect(HEVCAnnexB.isSampleUnit(Self.idr))
        #expect(HEVCAnnexB.isSampleUnit(Self.sei))
        #expect(!HEVCAnnexB.isSampleUnit(Self.vps))
        #expect(!HEVCAnnexB.isSampleUnit(Self.aud))
    }

    @Test func lengthPrefixesWithFourByteBigEndianSizes() {
        let out = HEVCAnnexB.lengthPrefixed([Self.idr, Self.sei])
        #expect(out == Data([0, 0, 0, 5]) + Self.idr + Data([0, 0, 0, 4]) + Self.sei)
    }
}
