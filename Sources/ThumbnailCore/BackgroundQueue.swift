import Foundation

/// Cooperative cancellation for synchronous file/image work. An operation that
/// has already entered a filesystem call finishes that call before returning.
public final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Keeps blocking work and mutable worker state on one serial dispatch queue.
public final class BackgroundQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    public init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    public func perform<Value: Sendable>(_ operation: @escaping @Sendable (WorkCancellation) throws -> Value) async throws -> Value {
        let cancellation = WorkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try autoreleasepool {
                            try cancellation.check()
                            return try operation(cancellation)
                        }
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}
