import Foundation

/// Guards asynchronous fetches against data-source switches.
///
/// Each switch starts a new generation. A fetch result is applied only if it belongs to the
/// current generation, so a slow fetch from an earlier session (for example GitHub CLI →
/// Fixtures → GitHub CLI) can never land in, or block refreshes of, the new session.
public struct SourceGenerations: Sendable {
    public private(set) var current = 0
    private var inFlight: Int?

    public init() {}

    public mutating func switchSource() {
        current += 1
        inFlight = nil
    }

    /// Returns the generation to tag a new fetch with, or nil if one is already running for it.
    public mutating func beginFetch() -> Int? {
        guard inFlight != current else { return nil }
        inFlight = current
        return current
    }

    /// Marks `generation`'s fetch finished. Returns true only if its result should be applied.
    public mutating func finishFetch(_ generation: Int) -> Bool {
        if inFlight == generation { inFlight = nil }
        return generation == current
    }
}
