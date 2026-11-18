import Foundation
import Testing

@testable import Convex

@Suite("Convex wire values")
struct CodingTests {
    @Test(arguments: [Int64.min, -1, 0, 1, Int64.max])
    func integerEnvelopeRoundTrips(_ value: Int64) throws {
        let encoded = try ConvexCodec.encode(value)
        #expect(encoded.contains("$integer"))
        #expect(try ConvexCodec.decode(Int64.self, from: encoded) == value)
        #expect(throws: (any Error).self) { try ConvexCodec.decode(Double.self, from: encoded) }
    }

    @Test(arguments: [Double.infinity, -.infinity, -.zero, .leastNonzeroMagnitude, 42.5])
    func floatingPointBitsSurvive(_ value: Double) throws {
        let encoded = try ConvexCodec.encode(value)
        let decoded = try ConvexCodec.decode(Double.self, from: encoded)
        #expect(decoded.bitPattern == value.bitPattern)
    }

    @Test func nanRemainsNan() throws {
        #expect(try ConvexCodec.decode(Double.self, from: ConvexCodec.encode(Double.nan)).isNaN)
    }

    @Test func bytesRemainBytes() throws {
        let bytes = Data([0, 1, 127, 128, 255])
        let encoded = try ConvexCodec.encode(bytes)
        #expect(try ConvexCodec.decode(Data.self, from: encoded) == bytes)
        #expect(throws: (any Error).self) { try ConvexCodec.decode([Double].self, from: encoded) }
    }

    @Test(arguments: [#"{"$integer":"AA=="}"#, #"{"$integer":"not base64"}"#, "2", "null"])
    func malformedIntegersThrow(_ json: String) {
        #expect(throws: (any Error).self) { try ConvexCodec.decode(Int64.self, from: json) }
    }

    @Test func nestedSpecialValuesUseConvexCoding() throws {
        let values: [Double?] = [nil, -.zero, .infinity, 5]
        let decoded = try ConvexCodec.decode([Double?].self, from: ConvexCodec.encode(values))
        #expect(decoded[0] == nil)
        #expect(decoded[1]?.bitPattern == (-Double.zero).bitPattern)
        #expect(decoded[2] == .infinity)
        #expect(decoded[3] == 5)
    }

    @Test func quotedRecordKeysAreEscaped() throws {
        let record = ["a\"b\\c": "value"]
        #expect(
            try ConvexCodec.decode([String: String].self, from: ConvexCodec.encode(record))
                == record
        )
    }

    @Test func nullAndMissingRemainDifferent() throws {
        let missing = try ConvexCodec.decode(PresenceRecord.self, from: #"{"required":null}"#)
        #expect(missing.required == nil)
        #expect(missing.optional == nil)
        if case .omitted = missing.nullable {
        } else {
            Issue.record("Missing field was not omitted")
        }

        let present = try ConvexCodec.decode(
            PresenceRecord.self,
            from: #"{"required":null,"nullable":null}"#
        )
        if case .value(nil) = present.nullable {} else { Issue.record("Null was not preserved") }
        #expect(try ConvexCodec.encode(present) == #"{"nullable":null,"required":null}"#)
        #expect(throws: (any Error).self) {
            try ConvexCodec.decode(PresenceRecord.self, from: "{}")
        }
        #expect(throws: (any Error).self) {
            try ConvexCodec.decode(PresenceRecord.self, from: #"{"required":null,"optional":null}"#)
        }
    }

    @Test func dynamicValuesPreserveWireKinds() throws {
        let json =
            #"{"bytes":{"$bytes":"AP8="},"int":{"$integer":"AQAAAAAAAAA="},"number":1,"null":null}"#
        let value = try ConvexCodec.decode(ConvexValue.self, from: json)
        guard case .object(let object) = value else {
            Issue.record("Expected object")
            return
        }
        #expect(object["int"] == .int64(1))
        #expect(object["number"] == .float64(1))
        #expect(object["bytes"] == .bytes(Data([0, 255])))
        #expect(object["null"] == .null)
        #expect(try ConvexCodec.decode(ConvexValue.self, from: ConvexCodec.encode(value)) == value)
    }

    @Test func unresolvedCommitTimestampIsRejected() {
        #expect(throws: (any Error).self) {
            try ConvexCodec.decode(ConvexValue.self, from: #"{"$commitTs":null}"#)
        }
    }
}

private struct PresenceRecord: ConvexValueCodable {
    let required: String?
    let optional: String?
    let nullable: ConvexField<String?>

    private enum CodingKeys: String, CodingKey { case required, optional, nullable }

    func encodeConvex(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeConvex(required, forKey: .required)
        try container.encodeConvexIfPresent(optional, forKey: .optional)
        try container.encodeConvexField(nullable, forKey: .nullable)
    }

    static func decodeConvex(from decoder: any Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        return try Self(
            required: container.decodeConvex(String?.self, forKey: .required),
            optional: container.decodeConvexIfPresent(String.self, forKey: .optional),
            nullable: container.decodeConvexField(String?.self, forKey: .nullable)
        )
    }
}
