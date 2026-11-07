import Foundation

/// Drives an on/off toggle (like, repost) to the server while the user keeps clicking.
///
/// Toggles may arrive while a request is in flight. Each one flips the pending target,
/// and the first caller loops here, sending requests until the server matches it.
/// Later callers only flip the target and return.
///
/// Returns the last state the server confirmed, plus the error that stopped the loop, if any.
/// A `target` of nil (e.g. pending state cleared on sign-out) ends the loop.
@MainActor
func syncToggle(
    from initial: Bool,
    target: () -> Bool?,
    send: (Bool) async throws -> Void
) async -> (confirmed: Bool, error: Error?) {
    var confirmed = initial
    do {
        while let next = target(), next != confirmed {
            try await send(next)
            confirmed = next
        }
    } catch {
        return (confirmed, error)
    }
    return (confirmed, nil)
}
