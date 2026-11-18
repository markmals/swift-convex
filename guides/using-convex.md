---
id: guide.using-convex
title: Using Generated Convex Requests
---

# Using Generated Convex Requests

Generate a Swift API from the backend's neutral contract before using these examples. The examples use the message/channel API in this repository's external consumer fixture. Your backend determines the available request types, fields, and outputs.

## Own one client

```swift
import Convex
import Foundation

let client = ConvexClient(deploymentURL: deploymentURL)
let request = API.Messages.List(channelID: channelID)
```

Keep the client for the application's connection lifetime. A generated request is an immutable value; constructing it performs no I/O. Its type fixes the function address, permitted operation, argument fields, and output. `DocumentID<API.Tables.Channels>` cannot be substituted with a message ID.

## Observe a live query

On the main actor, `client.observe(request)` returns a live `Query<API.Messages.List.Output>`. The model uses the system Observation framework, so reading its state in a SwiftUI view subscribes the view to state changes. Store the model in stable view state rather than constructing a new model each time `body` runs.

```swift
import Convex
import SwiftUI

@MainActor
struct MessagesView: View {
    @State private var messages: Query<API.Messages.List.Output>

    init(client: ConvexClient, channelID: DocumentID<API.Tables.Channels>) {
        _messages = State(initialValue: client.observe(API.Messages.List(channelID: channelID)))
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
```

Loading, a successful nullable output, and failure are different states. A failed query never substitutes an empty collection for an error. The model owns its subscription until cancellation or deinitialization. Visibility alone does not control its lifetime. When the request changes, create a new model; when deterministic teardown is needed, call `cancel()`.

## Consume snapshots as a sequence

```swift
let snapshots = client.snapshots(for: request)
defer { snapshots.cancel() }

for try await snapshot in snapshots {
    render(snapshot)
}
```

The sequence starts on iteration and supports one consumer. Create another sequence for an independent consumer. Values are result snapshots: a slow consumer may skip intermediate snapshots because the buffer retains only the newest. Terminal errors end the sequence. Task cancellation, iterator release, or explicit cancellation releases the native subscription, including when cancellation races with registration.

## Read once or perform an operation

```swift
let snapshot = try await client.fetch(request)
let messageID = try await client.execute(
    mutation: API.Messages.Send(body: "Hello", channelID: channelID)
)
try await client.execute(action: API.Notifications.Deliver(messageID: messageID))
```

`fetch(_:)` uses the shared Rust client's one-shot query. `execute(mutation:)` accepts only mutation requests; `execute(action:)` accepts only action requests. Each method infers its output from the request. Canceling a mutation/action wait does not imply server rollback or prove that the server did not execute it.

## Preserve wire meaning

Required nullable fields must be supplied, even when their value is nil. Optional nonnullable nil omits a field. Optional nullable fields use `ConvexField`: `.omitted` omits the key; `.value(nil)` sends null. Generated types preserve Int64 versus Float64, bytes envelopes, document brands, and exact wire keys. See the [contract format](contract-format.md) for the source semantics.

## Authenticate without the official Swift SDK

Supply an async token provider through `setAuthenticationProvider(_:)`. The application owns its sign-in UI and stored credentials; the provider receives refresh requests from the native client. Passing nil clears the provider. Token retrieval and connection state are observable local state, not proof of server authorization. The `ConvexMobile` Swift package is not a dependency and is not needed alongside `Convex`.
