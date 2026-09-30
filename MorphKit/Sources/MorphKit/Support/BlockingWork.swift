import Foundation

/// Runs synchronous, CPU- or IO-heavy work (ImageIO, libwebp, Rust codecs) on GCD instead of
/// Swift's cooperative thread pool, so long encodes never starve pipe readers or the UI.
public enum BlockingWork {
    public static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
