import Foundation

private struct RecordRestore<T: Identifiable & Equatable> {
    var id: T.ID
    var before: T?
    var after: T?
    var index: Int
    static func changes(_ before: [T], _ after: [T]) -> [Self] {
        let ids = Set(before.map(\.id)).union(after.map(\.id))
        return ids.compactMap { id in
            let a = before.first { $0.id == id }, b = after.first { $0.id == id }
            return a == b ? nil : Self(id: id, before: a, after: b, index: before.firstIndex { $0.id == id } ?? after.firstIndex { $0.id == id } ?? 0)
        }.sorted { $0.index < $1.index }
    }
    func restore(_ values: inout [T], matches: (T?, T?) -> Bool = { $0 == $1 }) {
        guard matches(values.first(where: { $0.id == id }), after) else { return }
        values.removeAll { $0.id == id }
        if let before { values.insert(before, at: min(index, values.count)) }
    }
}
/// Stores only touched records, never before/after BoardState or the unrelated notes string.
struct PreviewInverse {
    private var projects: [RecordRestore<Project>]
    private var countdowns: [RecordRestore<Milestone>]
    private var subscriptions: [RecordRestore<Subscription>]
    private var todos: [RecordRestore<Todo>]
    private var habits: [RecordRestore<Habit>]
    private var cities: [RecordRestore<WorldClockCity>]
    private var layout: (BoardLayout, BoardLayout)?
    private var settings: (BoardSettings, BoardSettings)?
    private var pins: [(String, Bool, Bool)]
    private var hidden: [(String, Bool, Bool)]
    private var links: [(String, String?, String?)]
    init(before: BoardState, after: BoardState) {
        projects = RecordRestore.changes(before.projects, after.projects)
        countdowns = RecordRestore.changes(before.milestones, after.milestones)
        subscriptions = RecordRestore.changes(before.subscriptions, after.subscriptions)
        todos = RecordRestore.changes(before.todos, after.todos); habits = RecordRestore.changes(before.habits, after.habits)
        cities = RecordRestore.changes(before.worldClockCities, after.worldClockCities)
        layout = before.layout == after.layout ? nil : (before.layout, after.layout)
        settings = before.settings == after.settings ? nil : (before.settings, after.settings)
        pins = before.pinnedEventKeys.symmetricDifference(after.pinnedEventKeys).map { ($0, before.pinnedEventKeys.contains($0), after.pinnedEventKeys.contains($0)) }
        hidden = before.hiddenCalendarIDs.symmetricDifference(after.hiddenCalendarIDs).map { ($0, before.hiddenCalendarIDs.contains($0), after.hiddenCalendarIDs.contains($0)) }
        links = Set(before.eventProjectLinks.keys).union(after.eventProjectLinks.keys).compactMap { key in
            before.eventProjectLinks[key] == after.eventProjectLinks[key] ? nil : (key, before.eventProjectLinks[key], after.eventProjectLinks[key])
        }
    }
    func apply(to board: inout BoardState) {
        for v in projects { v.restore(&board.projects) }; for v in countdowns { v.restore(&board.milestones) }
        for v in subscriptions {
            v.restore(&board.subscriptions) { current, expected in
                // ACK owns the real scheduler nonce. Match every displayed/business field
                // so a later record edit still blocks this source's optimistic inverse.
                if var current, let expected {
                    current.scheduleID = expected.scheduleID
                    return current == expected
                }
                return current == expected
            }
        }
        for v in todos { v.restore(&board.todos) }
        for v in habits { v.restore(&board.habits) }; for v in cities { v.restore(&board.worldClockCities) }
        if let (before, after) = layout, board.layout == after { board.layout = before }
        if let (before, after) = settings, board.settings == after { board.settings = before }
        for (id, before, after) in pins where board.pinnedEventKeys.contains(id) == after {
            if before { board.pinnedEventKeys.insert(id) } else { board.pinnedEventKeys.remove(id) }
        }
        for (id, before, after) in hidden where board.hiddenCalendarIDs.contains(id) == after {
            if before { board.hiddenCalendarIDs.insert(id) } else { board.hiddenCalendarIDs.remove(id) }
        }
        for (id, before, after) in links where board.eventProjectLinks[id] == after { board.eventProjectLinks[id] = before }
    }
}
