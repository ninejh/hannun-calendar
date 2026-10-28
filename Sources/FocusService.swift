import Foundation

/// Wall time determines durable deadlines; monotonic time only detects clock discontinuities.
struct PanelClockSnapshot: Sendable {
    var now: Instant
    var timeZone: TimeZone
    var monotonicMilliseconds: Int64

    func isContinuous(after previous: Self?) -> Bool {
        guard let previous, timeZone == previous.timeZone else { return false }
        let wall = now.date.timeIntervalSince(previous.now.date) * 1000
        let monotonic = monotonicMilliseconds.subtractingReportingOverflow(previous.monotonicMilliseconds)
        return !monotonic.overflow && monotonic.partialValue >= 0 && wall >= 0
            && abs(wall - Double(monotonic.partialValue)) <= 1000
    }
}

@MainActor
protocol PanelClock: AnyObject { var snapshot: PanelClockSnapshot { get } }

@MainActor
final class SystemPanelClock: PanelClock {
    var snapshot: PanelClockSnapshot {
        PanelClockSnapshot(now: Instant(date: Date()), timeZone: .current,
                           monotonicMilliseconds: Int64(ProcessInfo.processInfo.systemUptime * 1000))
    }
}

enum PanelClockEvent: Sendable { case tick, launch, wake, clockChanged, timeZoneChanged, interaction }
enum FocusCommand: Sendable { case start, pause, resume, stop, selectProject(UUID?), setMode(FocusMode) }

struct FocusServiceError: Error, Equatable, Sendable {
    enum Code: String, Sendable {
        case stateConflict = "FOCUS_STATE_CONFLICT", unknownProject = "UNKNOWN_PROJECT"
    }
    var code: Code
    /// A preceding elapsed-session reconciliation may already have committed.
    var committed: Bool = false
}

struct FocusProjectTime: Codable, Equatable, Sendable {
    var projectID: UUID
    var seconds: Int
    enum CodingKeys: String, CodingKey { case projectID, seconds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectID.uuidString.lowercased(), forKey: .projectID)
        try c.encode(seconds, forKey: .seconds)
    }
}

struct FocusProjection: Codable, Equatable, Sendable {
    var status: FocusStatus
    var mode: FocusMode
    var sessionID: UUID?
    var projectID: UUID?
    var plannedSeconds: Int
    var remainingSeconds: Int
    var endAt: Instant?
    var todayByProject: [FocusProjectTime]
    var unassignedTodaySeconds: Int
    var completionKind: FocusCompletionKind?
    enum CodingKeys: String, CodingKey {
        case status, mode, sessionID, projectID, plannedSeconds, remainingSeconds, endAt
        case todayByProject, unassignedTodaySeconds, completionKind
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(mode, forKey: .mode)
        try c.encode(sessionID?.uuidString.lowercased(), forKey: .sessionID)
        try c.encode(projectID?.uuidString.lowercased(), forKey: .projectID)
        try c.encode(plannedSeconds, forKey: .plannedSeconds); try c.encode(remainingSeconds, forKey: .remainingSeconds)
        try c.encode(endAt, forKey: .endAt); try c.encode(todayByProject, forKey: .todayByProject)
        try c.encode(unassignedTodaySeconds, forKey: .unassignedTodaySeconds)
        try c.encode(completionKind, forKey: .completionKind)
    }
}

struct FocusReconciliation: Sendable {
    var changed: Bool = false
    /// Ephemeral permission to notify a newly committed, normally observed completion.
    /// Launch, wake and clock jumps never produce it. The caller must consume it immediately.
    var finishedSessionID: UUID? = nil
}

/// The bridge invokes commands/reconcile in its existing mutation FIFO. BoardStore remains
/// the only writer; services have no independent copy of board.json or of its revision.
@MainActor
final class FocusService {
    private let store: BoardStore
    private let clock: any PanelClock
    private var previous: PanelClockSnapshot?

    init(store: BoardStore, clock: any PanelClock) { self.store = store; self.clock = clock }

    @discardableResult
    func command(_ command: FocusCommand) throws -> Bool {
        let reconciled = try reconcile(.interaction)
        let reading = clock.snapshot
        var next = store.state
        let before = next
        func conflict() -> FocusServiceError { FocusServiceError(code: .stateConflict, committed: reconciled.changed) }
        switch command {
        case let .selectProject(id):
            guard next.focusTimer.status == .idle || next.focusTimer.status == .completed else { throw conflict() }
            guard id == nil || next.projects.contains(where: { $0.id == id }) else { throw FocusServiceError(code: .unknownProject, committed: reconciled.changed) }
            next.focusTimer.projectID = id
        case let .setMode(mode):
            guard next.focusTimer.status == .idle || next.focusTimer.status == .completed else { throw conflict() }
            next.focusTimer.mode = mode
        case .start:
            guard next.focusTimer.status == .idle || next.focusTimer.status == .completed else { throw conflict() }
            let timer = next.focusTimer
            guard timer.projectID == nil || next.projects.contains(where: { $0.id == timer.projectID }) else { throw FocusServiceError(code: .unknownProject, committed: reconciled.changed) }
            let planned = timer.mode == .focus ? next.settings.focus.focusSeconds : next.settings.focus.breakSeconds
            next.focusTimer.session = FocusSession(id: UUID(), mode: timer.mode, projectIDAtStart: timer.projectID,
                currentProjectID: timer.projectID, plannedSeconds: planned, startedAt: reading.now,
                endAt: adding(planned, to: reading.now), activeSegment: FocusActiveSegment(startAt: reading.now, timeZone: reading.timeZone.identifier))
            next.focusTimer.status = .running
        case .pause:
            guard next.focusTimer.status == .running, var session = next.focusTimer.session, let end = session.endAt else { throw conflict() }
            try closeSegment(&session, until: min(reading.now, end))
            session.remainingSeconds = min(session.plannedSeconds, seconds(from: reading.now, to: end))
            session.endAt = nil; session.activeSegment = nil
            next.focusTimer.session = session; next.focusTimer.status = .paused
        case .resume:
            guard next.focusTimer.status == .paused, var session = next.focusTimer.session, let remaining = session.remainingSeconds else { throw conflict() }
            session.endAt = adding(remaining, to: reading.now); session.remainingSeconds = nil
            session.activeSegment = FocusActiveSegment(startAt: reading.now, timeZone: reading.timeZone.identifier)
            next.focusTimer.session = session; next.focusTimer.status = .running
        case .stop:
            guard next.focusTimer.status != .idle else { return reconciled.changed }
            if var session = next.focusTimer.session, session.completedAt == nil {
                if let end = session.endAt { try closeSegment(&session, until: min(reading.now, end)) }
                finish(&session, at: reading.now, kind: .stopped, in: &next)
            }
            next.focusTimer.session = nil; next.focusTimer.status = .idle
        }
        if next != before { try store.commit(next, baseRevision: before.boardRevision) }
        previous = reading
        return reconciled.changed || next != before
    }

    @discardableResult
    func reconcile(_ event: PanelClockEvent) throws -> FocusReconciliation {
        let reading = clock.snapshot
        let before = store.state
        var next = before
        var result = FocusReconciliation()
        if let selected = next.focusTimer.projectID, !next.projects.contains(where: { $0.id == selected }) {
            next.focusTimer.projectID = nil
        }
        if next.focusTimer.status == .running, var session = next.focusTimer.session,
           let end = session.endAt, let segment = session.activeSegment {
            let oldZone = TimeZone(identifier: segment.timeZone)!
            let continuous = reading.isContinuous(after: previous)
            let rewound = reading.now < (previous?.now ?? segment.startAt)
            let removedProject = session.currentProjectID.map { id in !next.projects.contains(where: { $0.id == id }) } ?? false
            if rewound {
                // Close only the previously observed positive interval. Moving the anchor to
                // the new wall instant cannot refund consumed time or enlarge the deadline.
                let anchor = max(segment.startAt, previous?.now ?? segment.startAt)
                try closeSegment(&session, until: min(anchor, end))
                let remaining = min(seconds(from: anchor, to: end), remainingBudgetSeconds(session))
                session.endAt = adding(remaining, to: reading.now)
                session.activeSegment = FocusActiveSegment(startAt: reading.now, timeZone: reading.timeZone.identifier)
                if removedProject { session.currentProjectID = nil }
                if remaining == 0 { finish(&session, at: reading.now, kind: .finished, in: &next); next.focusTimer.status = .completed }
            } else if reading.now >= end {
                try closeSegment(&session, until: end)
                if removedProject { session.currentProjectID = nil }
                finish(&session, at: end, kind: .finished, in: &next)
                next.focusTimer.status = .completed
                if event == .tick && continuous && reading.now.date.timeIntervalSince(end.date) < 60 {
                    result.finishedSessionID = session.id
                }
            } else {
                let crossedDay = DateOnly(date: segment.startAt.date, timeZone: oldZone) != DateOnly(date: reading.now.date, timeZone: oldZone)
                if event == .launch || event == .wake || event == .clockChanged || event == .timeZoneChanged
                    || !continuous || crossedDay || removedProject || oldZone != reading.timeZone {
                    try closeSegment(&session, until: reading.now)
                    if removedProject { session.currentProjectID = nil }
                    session.activeSegment = FocusActiveSegment(startAt: reading.now, timeZone: reading.timeZone.identifier)
                }
            }
            next.focusTimer.session = session
        } else if next.focusTimer.status == .paused, var session = next.focusTimer.session,
                  let id = session.currentProjectID, !next.projects.contains(where: { $0.id == id }) {
            session.currentProjectID = nil; next.focusTimer.session = session
        }
        result.changed = next != before
        if result.changed { try store.commit(next, baseRevision: before.boardRevision) }
        previous = reading
        return result
    }

    /// Read-only countdown: rendering a tick never persists a counter or increments revision.
    func projection() -> FocusProjection {
        let state = store.state, timer = state.focusTimer, reading = clock.snapshot
        let session = timer.session
        let planned = session?.plannedSeconds ?? (timer.mode == .focus ? state.settings.focus.focusSeconds : state.settings.focus.breakSeconds)
        let remaining: Int
        switch timer.status {
        case .idle: remaining = timer.mode == .focus ? state.settings.focus.focusSeconds : state.settings.focus.breakSeconds
        case .completed: remaining = 0
        case .paused: remaining = session?.remainingSeconds ?? 0
        case .running:
            let anchor = max(reading.now, previous?.now ?? reading.now)
            remaining = min(planned, session?.endAt.map { seconds(from: anchor, to: $0) } ?? 0)
        }
        let today = DateOnly(date: reading.now.date, timeZone: reading.timeZone)
        var seen = Set<UUID>(), totals: [UUID: Int] = [:], unassigned = 0
        // A completed session is present both in history and in the visible timer.
        // Interval identity, rather than tick count or either array's presence, is the ledger.
        for value in state.focusSessions + (session.map { [$0] } ?? []) where value.mode == .focus {
            for interval in value.intervals where interval.day == today && seen.insert(interval.id).inserted {
                if let id = interval.projectID { totals[id, default: 0] += interval.durationMilliseconds }
                else { unassigned += interval.durationMilliseconds }
            }
        }
        let projects = state.projects.compactMap { project in
            totals[project.id].map { FocusProjectTime(projectID: project.id, seconds: $0 / 1000) }
        }
        return FocusProjection(status: timer.status, mode: timer.mode, sessionID: session?.id, projectID: timer.projectID,
            plannedSeconds: planned, remainingSeconds: remaining, endAt: session?.endAt,
            todayByProject: projects, unassignedTodaySeconds: unassigned / 1000, completionKind: session?.completionKind)
    }

    private func seconds(from: Instant, to: Instant) -> Int {
        max(0, Int(ceil(to.date.timeIntervalSince(from.date))))
    }
    private func adding(_ seconds: Int, to instant: Instant) -> Instant {
        Instant(date: instant.date.addingTimeInterval(Double(seconds)))
    }
    private func remainingBudgetSeconds(_ session: FocusSession) -> Int {
        let used = session.intervals.reduce(0) { $0 + $1.durationMilliseconds }
        return max(0, (session.plannedSeconds * 1000 - used + 999) / 1000)
    }
    private func finish(_ session: inout FocusSession, at instant: Instant, kind: FocusCompletionKind, in state: inout BoardState) {
        session.completedAt = instant; session.completionKind = kind
        session.endAt = nil; session.remainingSeconds = nil; session.activeSegment = nil
        if let existing = state.focusSessions.first(where: { $0.id == session.id }) { session = existing }
        else { state.focusSessions.append(session) }
    }
    private func closeSegment(_ session: inout FocusSession, until instant: Instant) throws {
        guard let segment = session.activeSegment, instant > segment.startAt else { return }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: segment.timeZone) else { throw BoardStorageError(.invalidData) }
        calendar.timeZone = zone
        var cursor = segment.startAt.date
        let used = session.intervals.reduce(0) { $0 + $1.durationMilliseconds }
        var budget = session.plannedSeconds * 1000 - used
        while cursor < instant.date && budget > 0 {
            guard let dayEnd = calendar.dateInterval(of: .day, for: cursor)?.end, dayEnd > cursor,
                  let day = DateOnly(date: cursor, timeZone: zone) else { throw BoardStorageError(.invalidData) }
            let upper = min(instant.date, dayEnd, cursor.addingTimeInterval(Double(budget) / 1000))
            let milliseconds = Int((upper.timeIntervalSince(cursor) * 1000).rounded())
            guard milliseconds > 0 else { break }
            session.intervals.append(FocusInterval(id: UUID(), from: Instant(date: cursor), to: Instant(date: upper),
                day: day, timeZone: segment.timeZone, projectID: session.currentProjectID, durationMilliseconds: milliseconds))
            budget -= milliseconds; cursor = upper
        }
        session.activeSegment = FocusActiveSegment(startAt: instant, timeZone: segment.timeZone)
    }
}
