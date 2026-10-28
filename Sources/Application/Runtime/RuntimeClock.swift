import Foundation
import AppKit
import CoreFoundation
@preconcurrency import EventKit

@MainActor final class NativeApplicationClock: RuntimeClock {
    let panelClock: NativePanelClock
    let mode: RuntimeClockMode
    private var publishedDay: DateOnly?
    var preferences: NativePreferences { panelClock.preferences }
    init(configuration: ValidatedRuntimeConfiguration, preferences: NativePreferences) {
        mode = configuration.clock
#if HANNUN_TESTING
        if mode == .manual {
            if preferences.testNow == nil { preferences.testNow = Date() }
            if preferences.testTimeZone == nil { preferences.testTimeZone = .current }
        }
#endif
        panelClock = NativePanelClock(preferences, manual: configuration.clock == .manual)
        publishedDay = DateOnly(date: preferences.now, timeZone: preferences.timeZone)
    }
    var snapshot: ClockSnapshot {
        let continuous = panelClock.continuousSnapshot, awake = panelClock.snapshot
        let today = DateOnly(date: continuous.now.date, timeZone: continuous.timeZone)!
        return ClockSnapshot(now: continuous.now, today: today, timeZone: continuous.timeZone.identifier,
                             continuousMilliseconds: continuous.monotonicMilliseconds, awakeMilliseconds: awake.monotonicMilliseconds,
                             dayChanged: publishedDay.map { $0 != today } ?? false)
    }
    func didPublish(_ reading: ClockSnapshot) { publishedDay = reading.today }
#if HANNUN_TESTING
    /// Host/fixture control only. Normal production and normal demo always keep system time.
    func advance(milliseconds: Int64, sleeping: Bool = false) throws {
        guard mode == .manual, milliseconds >= 0 else { throw AppFailure(code: .invalidRequest) }
        let old = snapshot
        let continuous = old.continuousMilliseconds.addingReportingOverflow(milliseconds)
        let awake = old.awakeMilliseconds.addingReportingOverflow(sleeping ? 0 : milliseconds)
        let now = old.now.date.addingTimeInterval(Double(milliseconds) / 1000)
        guard !continuous.overflow, !awake.overflow, DateOnly(date: now, timeZone: preferences.timeZone) != nil else {
            throw AppFailure(code: .invalidRequest)
        }
        preferences.testNow = now
        panelClock.manualMilliseconds = awake.partialValue
        panelClock.continuousManualMilliseconds = continuous.partialValue
    }
    func setWall(_ now: Instant) throws {
        guard mode == .manual, DateOnly(date: now.date, timeZone: preferences.timeZone) != nil else {
            throw AppFailure(code: .invalidRequest)
        }
        preferences.testNow = now.date
    }
    func setTimeZone(_ identifier: String) throws {
        guard mode == .manual, let zone = TimeZone(identifier: identifier), DateOnly(date: preferences.now, timeZone: zone) != nil else {
            throw AppFailure(code: .invalidRequest)
        }
        preferences.testTimeZone = zone
    }
#endif
}

/// The only normal clock/midnight scheduler. App composition and private preflight call the
/// same NativeBoardApplication.start/stop, with no alternate low-frequency timer path.
@MainActor final class NativeRuntimeScheduler: RuntimeLifecycle {
    private weak var application: NativeBoardApplication?
    private var timer: Timer?
    private var midnight: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var appearance: NSKeyValueObservation?
    private var ticking = false
    private(set) var isRunning = false
    var timerCount: Int { (timer == nil ? 0 : 1) + (midnight == nil ? 0 : 1) }
    init(application: NativeBoardApplication) { self.application = application }
    func start() {
        guard !isRunning, let application else { return }
        isRunning = true
        guard application.configuration.clock == .system else { return }
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, !self.ticking, let application = self.application else { return }
                self.ticking = true
                defer { self.ticking = false }
                await application.processTimerTick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleMidnight()
        for (name, event) in [(NSNotification.Name.NSSystemClockDidChange, PanelClockEvent.clockChanged),
                              (.NSSystemTimeZoneDidChange, .timeZoneChanged), (NSLocale.currentLocaleDidChangeNotification, .interaction)] {
            observe(NotificationCenter.default, name: name, event: event)
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification, event: .wake)
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, event: .interaction)
        observe(NotificationCenter.default, name: .EKEventStoreChanged, event: .interaction, refreshCalendar: true)
        if let app = NSApp {
            appearance = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.application?.publishEnvironment() }
            }
        }
    }
    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate(); timer = nil
        midnight?.invalidate(); midnight = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll(); appearance?.invalidate(); appearance = nil
    }
    private func observe(_ center: NotificationCenter, name: Notification.Name, event: PanelClockEvent, refreshCalendar: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, let application = self.application else { return }
                application.publishEnvironment()
                await application.reconcile(event)
                self.scheduleMidnight()
                if refreshCalendar || event == .wake || event == .timeZoneChanged { await application.refreshCalendarIfDue(force: true) }
            }
        }
        observers.append((center, token))
    }
    private func scheduleMidnight() {
        midnight?.invalidate(); midnight = nil
        guard isRunning, let application else { return }
        let now = application.clock.preferences.now, calendar = application.clock.preferences.calendar
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        let timer = Timer(timeInterval: max(0.05, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                await self.application?.reconcile(.tick)
                self.scheduleMidnight()
            }
        }
        midnight = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
