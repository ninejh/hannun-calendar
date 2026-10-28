import Foundation
import Combine

@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var durableState: BoardState
    @Published private(set) var persistenceError: String?
    private(set) var lastFlushResult: Result<BoardState, BoardStorageError>?
    private let store: BoardStore
    private var candidate: BoardState?
    let demo: Bool

    /// Compatibility staging for the v1 bridge. Only flush/commit publishes a durable base.
    var state: BoardState {
        get { candidate ?? durableState }
        set { candidate = newValue }
    }
    var canSave: Bool { store.canSave }
    var nativeStore: BoardStore { store }

    init(demo: Bool, persistence: (any BoardPersistence)? = nil) {
        self.demo = demo
        if let persistence {
            store = BoardStore(persistence: persistence)
        } else if demo {
            store = BoardStore(initialState: DemoData.state)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let file = LocalStateFile(url: support.appendingPathComponent("HannunCalendar/board.json"))
            store = BoardStore(persistence: file)
        }
        durableState = store.state
        persistenceError = store.lastError?.localizedDescription
        store.didPublish = { [weak self] _, next in
            self?.durableState = next; self?.candidate = nil
            self?.persistenceError = self?.store.lastError?.localizedDescription
        }
    }

    @discardableResult
    func commit(_ next: BoardState, baseRevision: Int? = nil) -> Result<BoardState, BoardStorageError> {
        let result: Result<BoardState, BoardStorageError>
        do {
            let saved = try store.commit(next, baseRevision: baseRevision)
            result = .success(saved)
            persistenceError = nil
        } catch {
            let failure = (error as? BoardStorageError) ?? BoardStorageError(.writeFailed)
            result = .failure(failure)
            persistenceError = failure.localizedDescription
        }
        candidate = nil
        durableState = store.state
        lastFlushResult = result
        return result
    }

    /// Explicit inline Retry re-reads the protected source; defaults are never saved over it.
    @discardableResult
    func retryLoad() -> Result<BoardState, BoardStorageError> {
        let result: Result<BoardState, BoardStorageError>
        do {
            result = .success(try store.retryLoad())
            persistenceError = nil
        } catch {
            let failure = (error as? BoardStorageError) ?? BoardStorageError(.protectedData)
            result = .failure(failure)
            persistenceError = failure.localizedDescription
        }
        candidate = nil
        durableState = store.state
        lastFlushResult = result
        return result
    }

    @discardableResult
    func flush() -> Result<BoardState, BoardStorageError> {
        guard let candidate else {
            if let failure = store.lastError {
                let result: Result<BoardState, BoardStorageError> = .failure(failure)
                lastFlushResult = result
                return result
            }
            let result: Result<BoardState, BoardStorageError> = .success(durableState)
            lastFlushResult = result
            return result
        }
        return commit(candidate)
    }
}

enum DemoData {
    static let calendars = [
        CalendarInfo(id: "work", title: "Work", account: "Example · Google", colorHex: "557C68", writable: true),
        CalendarInfo(id: "personal", title: "Personal", account: "Example · iCloud", colorHex: "C48A46", writable: true),
        CalendarInfo(id: "study", title: "Research", account: "Example · Exchange", colorHex: "7D79A8", writable: true)
    ]
    static func date(_ day: Int, hour: Int = 10) -> Date {
        let d = DayMath.calendar.date(byAdding: .day, value: day, to: DayMath.calendar.startOfDay(for: Date()))!
        return DayMath.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: d)!
    }
    static var events: [CalendarItem] {
        let samples: [(String, Int, Int, Int, Bool)] = [
            ("Weekly planning", -3, 10, 0, false), ("Reading notes", -2, 14, 2, false),
            ("Team check-in", 0, 10, 0, false), ("Draft review", 0, 14, 2, false),
            ("Evening walk", 0, 19, 1, false), ("Design review", 1, 11, 0, false),
            ("Research meeting", 3, 14, 2, false), ("First results", 5, 10, 0, true),
            ("Dinner with friends", 7, 18, 1, false), ("Experiment review", 9, 11, 2, false),
            ("Paper deadline", 12, 10, 2, true), ("Launch day", 18, 10, 0, true)
        ]
        return samples.enumerated().map { index, value in
            let source = calendars[value.3]
            let start = value.4 ? DayMath.calendar.startOfDay(for: date(value.1)) : date(value.1, hour: value.2)
            // The preview also exercises imported all-day events with a same-day late end.
            let end = value.4 ? (index == 7 ? start.addingTimeInterval(23 * 3600 + 59 * 60) : DayMath.calendar.date(byAdding: .day, value: 1, to: start)!) : start.addingTimeInterval(3600)
            return CalendarItem(itemIdentifier: "sample-\(index)", eventIdentifier: "sample-\(index)",
                                calendarID: source.id, calendarTitle: source.title, colorHex: source.colorHex,
                                title: value.0, start: start, end: end, allDay: value.4,
                                location: "", notes: "This is a sample event for the preview.", recurring: false, writable: true)
        }
    }
    static var state: BoardState {
        var state = BoardState()
        state.projects = [
            Project(title: "Hannun Calendar", focus: "Building a calmer desktop workspace", nextStep: "Refine the layout after daily use", targetDate: date(18), colorHex: "557C68"),
            Project(title: "Research paper", focus: "Comparing results and shaping the draft", nextStep: "Review feedback before submission", targetDate: date(12), colorHex: "7D79A8"),
            Project(title: "Portfolio", focus: "Choosing the work worth sharing", nextStep: "Design the project pages", status: .waiting, colorHex: "C48A46")
        ]
        state.milestones = [Milestone(title: "Team milestone", date: date(2)), Milestone(title: "Monthly reflection", date: date(8), colorHex: "557C68")]
        state.notes = "A little room to think.\n\n• Finish one thing before starting another.\n• Gather references before the next meeting.\n\nEverything on this screen is sample data."
        return state
    }
}
