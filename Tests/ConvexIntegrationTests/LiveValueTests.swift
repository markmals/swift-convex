import Convex
import Foundation
import Testing

@Suite(
    "Live generated wire values",
    .enabled(if: ProcessInfo.processInfo.environment["CONVEX_INTEGRATION_URL"] != nil),
    .timeLimit(.minutes(1))
)
struct LiveValueTests {
    @Test func inferredSpecialValuesDecodeThroughTheRustRuntime() async throws {
        let special = try await liveClient().queryOnce(LiveAPI.Values.Special())
        #expect(special.nan.isNaN)
        #expect(special.positiveInfinity == .infinity)
        #expect(special.negativeInfinity == -.infinity)
        #expect(special.negativeZero.bitPattern == (-Double.zero).bitPattern)
        #expect(special.int64Min == .min)
        #expect(special.int64Max == .max)
        #expect(special.bytes == Data([0, 1, 254, 255]))
        #expect(special.pair.element0 == "left")
        #expect(special.pair.element1 == 1)
        #expect(special.tag == .special)
        #expect(special.version == .integer1)
        let keys = try ConvexCodec.decode(
            [String: String].self,
            from: ConvexCodec.encode(special.keys)
        )
        #expect(keys == ["kebab-case": "dash", "with space": "space", "dot.ted": "dot"])
    }

    @Test(arguments: [ConvexField<Double?>.omitted, .value(nil), .value(12.5)])
    func echoPreservesWireKindsAndNullablePresence(_ presence: ConvexField<Double?>) async throws {
        let request = LiveAPI.Values.Echo(
            array: [.nan, .infinity, -.infinity, -Double.zero],
            boolean: true,
            bytes: Data([0, 1, 254, 255]),
            float: -Double.zero,
            int: .min,
            literal: .alpha,
            nothing: ConvexNull(),
            nullable: nil,
            object: .init(class: "keyword", default: .max, snakeCase: true),
            optionalNullable: presence,
            record: ["edge": .nan],
            shape: .circle(.init(radius: 2.5, kind: .circle)),
            string: "quotes \" and newline\n",
            union: .int64(.max)
        )
        let response = try await liveClient().queryOnce(request)
        #expect(response.array[0].isNaN)
        #expect(response.array[1] == .infinity)
        #expect(response.array[2] == -.infinity)
        #expect(response.array[3].bitPattern == (-Double.zero).bitPattern)
        #expect(response.boolean)
        #expect(response.bytes == request.bytes)
        #expect(response.float.bitPattern == request.float.bitPattern)
        #expect(response.int == .min)
        #expect(response.literal == .alpha)
        #expect(response.nothing == ConvexNull())
        #expect(response.nullable == nil)
        #expect(response.object.`class` == "keyword")
        #expect(response.object.`default` == .max)
        #expect(response.object.snakeCase)
        #expect(response.optional == nil)
        #expect(response.optionalNullable == presence)
        #expect(response.record["edge"]?.isNaN == true)
        #expect(response.string == request.string)
        if case .circle(let circle) = response.shape {
            #expect(circle.radius == 2.5)
            #expect(circle.kind == .circle)
        } else {
            Issue.record("Discriminated shape changed case")
        }
        if case .int64(let value) = response.union {
            #expect(value == .max)
        } else {
            Issue.record("Int64 union changed wire kind")
        }
    }
}
