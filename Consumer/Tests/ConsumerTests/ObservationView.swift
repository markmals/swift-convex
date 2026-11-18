import Convex
import SwiftUI

@MainActor
private struct MessagesView: View {
    @State private var messages: Query<API.Messages.List.Output>

    init(client: ConvexClient, channelID: DocumentID<API.Tables.Channels>) {
        _messages = State(initialValue: client.query(API.Messages.List(channelID: channelID)))
    }

    var body: some View {
        switch messages.state {
        case .loading:
            ProgressView()
        case .value(let values):
            List(values, id: \.id) { message in
                Text(message.body)
            }
        case .failed(let error):
            Text(String(describing: error))
        }
    }
}
