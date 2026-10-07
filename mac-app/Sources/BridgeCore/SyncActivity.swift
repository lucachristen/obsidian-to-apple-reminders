import Foundation

/// Presentation timing only. Internal sync work must never depend on visibility.
public struct SyncActivity {
    public private(set) var isVisible = false
    public private(set) var nextTransition: TimeInterval?
    private var running = false
    private var visibleSince: TimeInterval?
    private let backgroundDelay: TimeInterval
    private let minimumVisibility: TimeInterval

    public init(backgroundDelay: TimeInterval = 0.4, minimumVisibility: TimeInterval = 0.5) {
        self.backgroundDelay = backgroundDelay
        self.minimumVisibility = minimumVisibility
    }
    public mutating func begin(at now: TimeInterval, userInitiated: Bool) {
        running = true
        if userInitiated || isVisible {
            if !isVisible { visibleSince = now }
            isVisible = true
            nextTransition = nil
        } else if nextTransition == nil {
            nextTransition = now + backgroundDelay
        }
    }
    public mutating func finish(at now: TimeInterval) {
        running = false
        if let visibleSince {
            nextTransition = max(now, visibleSince + minimumVisibility)
            advance(to: now)
        } else {
            nextTransition = nil
        }
    }
    public mutating func advance(to now: TimeInterval) {
        guard let nextTransition, now >= nextTransition else { return }
        self.nextTransition = nil
        isVisible = running
        visibleSince = running ? now : nil
    }
}
