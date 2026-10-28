import Foundation

/// Display-only state transitions. Durable sessions, intervals, totals and notification effects
/// are exclusively the native service's projection; no deadline is sent back as a command field.
enum FocusPreview {
    static func apply(_ command: FocusCommand, operationID: UUID, admittedAt: Instant, to snapshot: inout BoardSnapshot) {
        var focus = snapshot.focus
        func configuredSeconds() -> Int {
            focus.mode == .focus ? snapshot.board.settings.focus.focusSeconds : snapshot.board.settings.focus.breakSeconds
        }
        func remaining(until end: Instant) -> Int {
            min(focus.plannedSeconds, max(0, Int(ceil(end.date.timeIntervalSince(admittedAt.date)))))
        }
        switch command {
        case .selectProject(let id):
            guard focus.status == .idle || focus.status == .completed,
                  id == nil || snapshot.board.projects.contains(where: { $0.id == id }) else { return }
            focus.projectID = id
        case .setMode(let mode):
            guard focus.status == .idle || focus.status == .completed else { return }
            focus.mode = mode
            if focus.status == .idle { focus.plannedSeconds = configuredSeconds(); focus.remainingSeconds = focus.plannedSeconds }
        case .start:
            guard focus.status == .idle || focus.status == .completed,
                  focus.projectID == nil || snapshot.board.projects.contains(where: { $0.id == focus.projectID }) else { return }
            let planned = configuredSeconds()
            guard planned > 0 && planned <= 240 * 60 else { return }
            focus.status = .running; focus.sessionID = operationID
            focus.plannedSeconds = planned; focus.remainingSeconds = planned
            focus.endAt = Instant(date: admittedAt.date.addingTimeInterval(Double(planned)))
            focus.completionKind = nil
        case .pause:
            guard focus.status == .running, let end = focus.endAt else { return }
            focus.remainingSeconds = remaining(until: end); focus.endAt = nil; focus.status = .paused
        case .resume:
            guard focus.status == .paused else { return }
            focus.endAt = Instant(date: admittedAt.date.addingTimeInterval(Double(focus.remainingSeconds)))
            focus.status = .running; focus.completionKind = nil
        case .stop:
            guard focus.status != .idle else { return }
            focus.status = .idle; focus.sessionID = nil; focus.endAt = nil; focus.completionKind = nil
            focus.plannedSeconds = configuredSeconds(); focus.remainingSeconds = focus.plannedSeconds
        }
        snapshot.focus = focus
    }
}
