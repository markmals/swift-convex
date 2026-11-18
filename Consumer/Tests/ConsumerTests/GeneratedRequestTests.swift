import Convex
import Testing

@Suite("Generated request contracts")
struct GeneratedRequestTests {
    @Test func queryArgumentsUseOriginalBackendNames() throws {
        let channelID = DocumentID<API.Tables.Channels>(uncheckedRawValue: "channel-id")
        let request = API.Messages.List(channelID: channelID)
        #expect(API.Messages.List.functionPath == "messages:list")
        #expect(try request.encodeArguments() == ["channelId": #""channel-id""#])
    }

    @Test func optionalNullableArgumentsPreserveOmission() throws {
        let channelID = DocumentID<API.Tables.Channels>(uncheckedRawValue: "channel-id")
        let omitted = API.Messages.Send(body: "hello", channelID: channelID)
        #expect(try omitted.encodeArguments()["note"] == nil)
        let null = API.Messages.Send(body: "hello", channelID: channelID, note: .value(nil))
        #expect(try null.encodeArguments()["note"] == "null")
    }

    @Test func generatedOutputChecksDocumentIdentityAndPresence() throws {
        let json =
            #"[{"_creationTime":42.5,"_id":"message-id","channelId":"channel-id","body":"hello","note":null}]"#
        let messages = try ConvexCodec.decode(API.Messages.List.Output.self, from: json)
        let message = try #require(messages.first)
        #expect(message.id.rawValue == "message-id")
        #expect(message.channelID.rawValue == "channel-id")
        #expect(message.creationTime == 42.5)
        if case .value(nil) = message.note {
        } else {
            Issue.record("Explicit null was not preserved")
        }
        #expect(throws: (any Error).self) {
            try ConvexCodec.decode(API.Messages.List.Output.self, from: #"[{"_id":"message-id"}]"#)
        }
    }
}
