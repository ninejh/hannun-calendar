import Foundation

struct DeadlineRow: Equatable {
    enum Source: Equatable { case event(String), project(UUID), countdown(UUID) }
    var id: String
    var source: Source
    var title: String
    var day: DateOnly
    var origin: String
    var originKey: String?
}
enum DeadlineRows {
    static func group(_ snapshot: BoardSnapshot) -> (active: [DeadlineRow], past: [DeadlineRow]) {
        let board = snapshot.board, today = snapshot.clock.today
        let zone = TimeZone(identifier: snapshot.environment.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        var active: [DeadlineRow] = [], past: [DeadlineRow] = []
        for event in snapshot.calendar.records where !board.hiddenCalendarIDs.contains(event.item.calendarID) && (!board.settings.importantOnly || board.pinnedEventKeys.contains(event.pinKey)) {
            guard let day = DateOnly(date: event.item.start, timeZone: zone), day >= today else { continue }
            active.append(DeadlineRow(id: "event." + event.id, source: .event(event.id), title: event.item.title, day: day, origin: event.item.calendarTitle))
        }
        for item in board.milestones {
            let row = DeadlineRow(id: "countdown." + item.id.uuidString.lowercased(), source: .countdown(item.id), title: item.title, day: item.day, origin: "", originKey: "deadlines.countdown_origin")
            if item.day < today { past.append(row) } else { active.append(row) }
        }
        for project in board.projects where project.status != .done {
            guard let day = project.targetDay else { continue }
            active.append(DeadlineRow(id: "project." + project.id.uuidString.lowercased(), source: .project(project.id), title: project.title, day: day, origin: "", originKey: "projects.target_origin"))
        }
        func ordered(_ rows: [DeadlineRow]) -> [DeadlineRow] { rows.enumerated().sorted { $0.element.day == $1.element.day ? $0.offset < $1.offset : $0.element.day < $1.element.day }.map(\.element) }
        return (ordered(active), ordered(past))
    }
    @MainActor static func badge(day: DateOnly, today: DateOnly, context: BoardScreenContext) -> String {
        let difference = day.ordinal - today.ordinal
        return difference == 0 ? context.text("deadlines.day") : context.text(difference > 0 ? "deadlines.remaining" : "deadlines.elapsed", values: ["0": String(abs(difference))])
    }
}
