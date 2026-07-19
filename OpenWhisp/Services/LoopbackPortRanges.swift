import Foundation

// MARK: - Loopback port ranges (pure port-selection contract)

/// The loopback port bands OpenWhisp's two bundled servers pick from, plus the
/// pure candidate-ordering the reservation uses. Extracted into core (MAK-85) so
/// the two invariants the port-selection design leans on are UNIT-TESTED rather
/// than living only as app-only constants:
///
///   1. **Disjointness** — whisper-server and llama-server draw from
///      non-overlapping ranges so the two engines probing concurrently at startup
///      can never land on the same candidate (the "sibling race" in MAK-28). If a
///      future edit slides one band into the other, a test fails instead of a
///      once-in-a-blue-moon startup collision shipping.
///   2. **Full coverage** — the randomised candidate order the reservation walks
///      must be a permutation of the whole band (every port tried exactly once),
///      so a busy host still exhausts the range before giving up.
///
/// ## What this does NOT cover (live-only)
///
/// The actual TOCTOU fix — bind a probe socket, HOLD it open until the instant
/// before the child binds, so a concurrent in-process reservation can't pick the
/// same number (`ManagedServerProcess.reservePort` / `ReservedPort`) — is a
/// property of the OS socket layer and `Process.run()` timing. It can't be
/// exercised by a Foundation-only unit test (it needs real `bind()`s and a real
/// spawn), so it's validated live (two engines starting concurrently) and by the
/// `ServerLaunchRetry` decision (a lost race surfaces as a retryable health
/// failure). This type pins the pure half: the ranges are disjoint and the walk
/// covers them.
public enum LoopbackPortRanges {

    /// whisper-server's band — the LOWER half.
    public static let whisper: ClosedRange<Int> = 8178...8677

    /// llama-server's band — the UPPER half. Disjoint from `whisper` (see the
    /// type doc); `disjoint` asserts it, and a test enforces it.
    public static let llama: ClosedRange<Int> = 8678...9177

    /// True iff the two bands share no port. The whole point of separate ranges;
    /// exposed so a unit test can assert it holds after any future edit.
    public static var disjoint: Bool {
        whisper.upperBound < llama.lowerBound || llama.upperBound < whisper.lowerBound
    }

    /// A randomised order in which to probe `range`'s candidates. A permutation
    /// of the whole band — every port appears exactly once — so a reservation
    /// walking it tries the entire range before giving up. `ManagedServerProcess`
    /// uses `range.shuffled()` directly; this is the same contract, named and
    /// tested (and injectable for a deterministic test via `using:`).
    public static func candidateOrder(
        in range: ClosedRange<Int>,
        using shuffle: (Array<Int>) -> [Int] = { $0.shuffled() }
    ) -> [Int] {
        shuffle(Array(range))
    }
}
