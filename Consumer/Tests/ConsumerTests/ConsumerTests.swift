import Convex
import Foundation
import Testing

@Suite("Public Convex contracts")
struct ConsumerTests {
    @Test func integerAndNumberStayDistinct() throws {
        let integer = try ConvexCodec.encode(Int64.max)
        #expect(try ConvexCodec.decode(Int64.self, from: integer) == .max)
        #expect(throws: (any Error).self) { try ConvexCodec.decode(Double.self, from: integer) }
    }

    @Test func specialValuesWorkInsideCollections() throws {
        let values: [Double?] = [nil, -.infinity, -.zero]
        let decoded = try ConvexCodec.decode([Double?].self, from: ConvexCodec.encode(values))
        #expect(decoded[0] == nil)
        #expect(decoded[1] == -.infinity)
        #expect(decoded[2]?.sign == .minus)
    }

    @Test func typedIDsPreserveWireStrings() throws {
        let identifier = DocumentID<Messages>(uncheckedRawValue: "opaque-id")
        #expect(try ConvexCodec.encode(identifier) == #""opaque-id""#)
        #expect(
            try ConvexCodec.decode(DocumentID<Messages>.self, from: #""opaque-id""#) == identifier
        )
    }
}

private enum Messages: ConvexTable {
    static let name = "messages"
}
