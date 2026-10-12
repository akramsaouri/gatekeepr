import AppKit
import Combine
import Foundation
import GatekeeprCore

/// Delivers notifications. The app's implementation uses UNUserNotificationCenter.
@MainActor
public protocol SessionNotifier: AnyObject {
    func post(_ notification: SessionNotification)
    /// Removes delivered notifications once a new session has made them stale.
    func withdrawAll()
}

/// The menu bar app's state. It reads the logs through GatekeeprCore whenever
/// they change (no polling), ticks the countdown once a minute, and sends the
/// warning and expiry notifications once per session.
@MainActor
public final class StatusModel: ObservableObject {
    @Published public private(set) var state: MenuState = .loading

    /// Persisted. Changing it re-evaluates straight away, which can send the
    /// warning if the session is now inside the window.
    @Published public var warnThreshold: TimeInterval {
        didSet {
            preferences.warnThreshold = warnThreshold
            evaluate()
        }
    }

    public var warnThresholdChoices: [TimeInterval] {
        Preferences.warnThresholdChoices(including: warnThreshold)
    }

    /// Called after every evaluation, so the app can refresh system state that
    /// can change behind its back (notification permission, login item).
    public var onEvaluate: (() -> Void)?

    public let logDirectory: URL
    private let preferences: Preferences
    private let notifier: SessionNotifier
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    private let loader: LogLoader

    private var latest: Result<Analysis, Error>?
    private var latestGeneration = 0
    /// The current session's start, to notice when a new one begins.
    private var currentSession: Date?
    private var tick: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(
        logDirectory: URL = LogDirectory.appgateDefault,
        preferences: Preferences = Preferences(),
        notifier: SessionNotifier,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.logDirectory = logDirectory
        self.preferences = preferences
        self.notifier = notifier
        self.clock = clock
        self.timeZone = timeZone
        warnThreshold = preferences.warnThreshold
        loader = LogLoader(gatekeepr: Gatekeepr(logDirectory: logDirectory, clock: clock))
    }

    /// Starts watching the logs and reads them once.
    public func start() {
        loader.deliver = { [weak self] result, generation in
            Task { @MainActor in self?.receive(result, generation: generation) }
        }
        loader.start()
        // The countdown timer doesn't run while the Mac sleeps, and the clock can
        // jump: catch up straight away. Waking also re-reads the logs, in case
        // something happened that the file watch hasn't delivered yet.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { model in
            model.evaluate()
            model.loader.reload()
        }
        observe(.default, .NSSystemClockDidChange) { $0.evaluate() }
    }

    public func stop() {
        loader.stop()
        tick?.cancel()
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
    }

    /// Takes a fresh read of the logs. Results arrive in order, but they are
    /// delivered through tasks, so an older one can turn up late: drop it.
    func receive(_ result: Result<Analysis, Error>, generation: Int) {
        guard generation > latestGeneration else { return }
        latestGeneration = generation
        latest = result
        evaluate()
    }

    /// Works out the state at the current time from the latest read.
    func evaluate() {
        tick?.cancel()
        tick = nil
        switch latest {
        case nil:
            return
        case let .failure(error)?:
            // Never fall back to an old answer: the menu says what's wrong instead.
            state = MenuState(error: error)
        case let .success(analysis)?:
            let analysis = analysis.at(clock())
            let status = analysis.status(warnThreshold: warnThreshold)
            state = MenuState(status: status, analysis: analysis, logDirectory: logDirectory.path, timeZone: timeZone)
            notifyIfDue(status)
            scheduleTick(after: MenuState.refreshDelay(timeLeft: status.timeLeft))
        }
        onEvaluate?()
    }

    private func notifyIfDue(_ status: Status) {
        let session = status.session?.start
        if let previous = currentSession, let session, session != previous {
            // A new sign-in or renewal: "expires in 30m" no longer applies.
            notifier.withdrawAll()
        }
        currentSession = session

        var ledger = preferences.ledger
        guard let notification = NotificationPlanner.due(for: status, ledger: ledger, timeZone: timeZone) else { return }
        ledger.record(notification)
        preferences.ledger = ledger
        notifier.post(notification)
    }

    private func scheduleTick(after delay: TimeInterval) {
        tick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (StatusModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}

/// Reads the logs on a background queue whenever the watcher says they changed.
final class LogLoader {
    /// How long to wait before reading again after a failed read. A rotated
    /// file can be caught half-written; a retry saves showing an error until
    /// the next log line.
    static let retryDelay: TimeInterval = 2

    /// Called on the loader's queue, in order, with a rising generation number.
    var deliver: ((Result<Analysis, Error>, Int) -> Void)?

    private let gatekeepr: Gatekeepr
    private let queue = DispatchQueue(label: "gatekeepr.logs", qos: .utility)
    private var watcher: LogWatcher?
    private var generation = 0

    init(gatekeepr: Gatekeepr) {
        self.gatekeepr = gatekeepr
    }

    func start() {
        let watcher = LogWatcher(directory: gatekeepr.logDirectory.url, queue: queue) { [weak self] in
            self?.load(retryOnFailure: true)
        }
        self.watcher = watcher
        watcher.start()
        reload()
    }

    func reload() {
        queue.async { [weak self] in self?.load(retryOnFailure: true) }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func load(retryOnFailure: Bool) {
        generation += 1
        let result = Result { try gatekeepr.analyze() }
        deliver?(result, generation)
        if case .failure = result, retryOnFailure {
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.load(retryOnFailure: false)
            }
        }
    }
}
