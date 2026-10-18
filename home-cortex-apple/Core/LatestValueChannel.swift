import Foundation

/// Producers never wait and consumers retain at most one pending value.
struct LatestValueChannel<Value: Sendable>: Sendable {
    let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func send(_ value: Value) { continuation.yield(value) }
    func finish() { continuation.finish() }
}
