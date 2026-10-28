import Foundation

@MainActor enum NativeBoardMutator {
    static func atoms(_ edit: BoardEdit) -> [AtomicBoardEdit] {
        switch edit {
        case .notes(let value): [.notes(value)]
        case .project(let value): [.project(value)]
        case .countdown(let value): [.countdown(value)]
        case .pin(let id, let value): [.pin(id, value)]
        case .eventProject(let id, let value): [.eventProject(id, value)]
        case .calendarVisibility(let id, let hidden): [.calendarVisibility(id: id, isHidden: hidden)]
        case .settings(let patch): [.settings(patch)]
        case .layout(let value): [.layout(value)]
        case .panel(let value): [.panel(value)]
        case .transaction(let values): values
        }
    }
    static func assign<T>(_ change: FieldChange<T>, to value: inout T) {
        if case .set(let next) = change { value = next }
    }
    static func title(_ text: String, field: FieldPath? = nil) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500 else {
            throw AppFailure(code: .validationFailed, field: field)
        }
    }
    static func color(_ input: String) throws -> String {
        let color = input.hasPrefix("#") ? String(input.dropFirst()) : input
        guard color.utf8.count == 6, color.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw AppFailure(code: .validationFailed)
        }
        return color.uppercased()
    }
    static func apply(_ edit: BoardEdit, to board: BoardState, calendars: CalendarService,
                      clock: ClockSnapshot, cityIDs: Set<String>) throws -> BoardState {
        let edits = atoms(edit)
        guard !edits.isEmpty, edits.count <= 10000 else { throw AppFailure(code: .invalidRequest) }
        var next = board
        for atom in edits {
            switch atom {
            case .notes(let value):
                guard value.utf8.count <= 1024 * 1024 else { throw AppFailure(code: .validationFailed, field: .notes) }
                next.notes = value
            case .project(let value):
                switch value {
                case .create(let input):
                    guard !next.projects.contains(where: { $0.id == input.id }) else { throw AppFailure(code: .boardConflict) }
                    try title(input.title, field: .project(input.id, .title))
                    var project = Project(title: input.title)
                    project.id = input.id; project.focus = input.focus; project.nextStep = input.nextStep
                    project.status = input.status; project.targetDay = input.targetDay
                    project.colorHex = try color(input.colorHex); project.progress = input.progress
                    next.projects.append(project)
                case .update(let id, let patch):
                    guard let index = next.projects.firstIndex(where: { $0.id == id }) else { throw AppFailure(code: .unknownProject) }
                    var value = next.projects[index]
                    assign(patch.title, to: &value.title); assign(patch.focus, to: &value.focus)
                    assign(patch.nextStep, to: &value.nextStep); assign(patch.status, to: &value.status)
                    assign(patch.targetDay, to: &value.targetDay); assign(patch.progress, to: &value.progress)
                    if case .set(let colorValue) = patch.colorHex { value.colorHex = try color(colorValue) }
                    try title(value.title, field: .project(id, .title)); next.projects[index] = value
                case .delete(let id):
                    guard next.projects.contains(where: { $0.id == id }) else { throw AppFailure(code: .unknownProject) }
                    next.projects.removeAll { $0.id == id }
                    next.eventProjectLinks = next.eventProjectLinks.filter { $0.value.lowercased() != id.uuidString.lowercased() }
                }
            case .countdown(let value):
                switch value {
                case .create(let input):
                    guard !next.milestones.contains(where: { $0.id == input.id }) else { throw AppFailure(code: .boardConflict) }
                    try title(input.title, field: .countdown(input.id, .title))
                    var item = Milestone(id: input.id, title: input.title, date: input.day.date(in: TimeZone(secondsFromGMT: 0)!))
                    item.day = input.day; item.colorHex = try color(input.colorHex); next.milestones.append(item)
                case .update(let id, let patch):
                    guard let index = next.milestones.firstIndex(where: { $0.id == id }) else { throw AppFailure(code: .boardConflict) }
                    assign(patch.title, to: &next.milestones[index].title); assign(patch.day, to: &next.milestones[index].day)
                    if case .set(let value) = patch.colorHex { next.milestones[index].colorHex = try color(value) }
                    try title(next.milestones[index].title, field: .countdown(id, .title))
                case .delete(let id):
                    guard next.milestones.contains(where: { $0.id == id }) else { throw AppFailure(code: .boardConflict) }
                    next.milestones.removeAll { $0.id == id }
                }
            case .pin(let identity, let pinned):
                guard let event = calendars.find(identity.id) else { throw AppFailure(code: .eventNotFound) }
                if pinned { next.pinnedEventKeys.insert(event.pinKey) } else { next.pinnedEventKeys.remove(event.pinKey) }
            case .eventProject(let identity, let id):
                guard let event = calendars.find(identity.id) else { throw AppFailure(code: .eventNotFound) }
                guard id == nil || next.projects.contains(where: { $0.id == id }) else { throw AppFailure(code: .unknownProject) }
                next.eventProjectLinks[event.pinKey] = id?.uuidString.lowercased()
            case .calendarVisibility(let id, let hidden):
                guard calendars.calendars.contains(where: { $0.id == id }) || next.hiddenCalendarIDs.contains(id) else {
                    throw AppFailure(code: .calendarNotFound)
                }
                if hidden { next.hiddenCalendarIDs.insert(id) } else { next.hiddenCalendarIDs.remove(id) }
            case .settings(let patch): try applySettings(patch, to: &next.settings, cityIDs: cityIDs)
            case .layout(let value):
                switch value {
                case .select(let slot, let panel): next = try Self.panel(.selectSlot(slot, panel), board: next, clock: clock, cityIDs: cityIDs)
                case .setHidden(let slot, let hidden):
                    if hidden { next.layout.hiddenSlots.insert(slot.rawValue) } else { next.layout.hiddenSlots.remove(slot.rawValue) }
                case .reset: next = try panel(.resetLayout, board: next, clock: clock, cityIDs: cityIDs)
                case .setStep(let split, let step, let viewport):
                    do { next.layout = try LayoutStepResolver.resolve(layout: next.layout, split: split, step: step, viewport: viewport) }
                    catch { throw AppFailure(code: .validationFailed, field: .layout(split)) }
                case .setSplit(let split, _):
                    // Compatibility spelling while consumers migrate; ratios/null are not writable.
                    throw AppFailure(code: .validationFailed, field: .layout(split))
                }
            case .panel(let value): next = try panel(value, board: next, clock: clock, cityIDs: cityIDs)
            }
        }
        do { try next.validate() } catch { throw AppFailure(code: .validationFailed) }
        return next
    }
    private static func panel(_ intent: PanelIntent, board: BoardState, clock: ClockSnapshot, cityIDs: Set<String>) throws -> BoardState {
        do { return try PanelDomain.apply(intent, to: board, now: clock.now, today: clock.today, validCityIDs: cityIDs).state }
        catch let error as PanelDomainError {
            var failure = NativeRuntimeErrors.normalize(error)
            if let raw = error.field, let field = PanelField(rawValue: raw) {
                let panel: PanelID, id: UUID?
                switch intent {
                case .createSubscription(let input): panel = .subscriptions; id = input.id
                case .updateSubscription(let value, _), .deleteSubscription(let value): panel = .subscriptions; id = value
                case .createTodo(let value, _), .updateTodo(let value, _), .deleteTodo(let value): panel = .todos; id = value
                case .createHabit(let value, _), .updateHabit(let value, _), .setHabitToday(let value, _, _), .deleteHabit(let value): panel = .habits; id = value
                case .addCity, .deleteCity: panel = .worldClock; id = nil
                default: panel = .today; id = nil
                }
                failure.field = .panel(panel, id: id, field: field)
            }
            throw failure
        }
    }
    private static func applySettings(_ patch: SettingsPatch, to settings: inout BoardSettings, cityIDs: Set<String>) throws {
        assign(patch.desktopMode, to: &settings.desktopMode); assign(patch.fontScale, to: &settings.fontScale)
        assign(patch.opacity, to: &settings.opacity); assign(patch.importantOnly, to: &settings.importantOnly)
        assign(patch.showCompletedProjects, to: &settings.showCompletedProjects); assign(patch.appearance, to: &settings.appearance)
        assign(patch.compact, to: &settings.compact); assign(patch.language, to: &settings.language)
        assign(patch.weekStart, to: &settings.weekStart); assign(patch.networkEnabled, to: &settings.networkEnabled)
        assign(patch.ratesEnabled, to: &settings.ratesEnabled); assign(patch.weather, to: &settings.weather)
        assign(patch.todosCompletedCollapsed, to: &settings.todosCompletedCollapsed)
        if case .set(let value) = patch.focus {
            guard !value.notifyOnFinish || settings.focus.notifyOnFinish else { throw AppFailure(code: .notificationPermissionRequired) }
            settings.focus = value
        }
        guard settings.fontScale.isFinite, (0.9...1.5).contains(settings.fontScale),
              settings.opacity.isFinite, (0.75...1).contains(settings.opacity) else { throw AppFailure(code: .validationFailed) }
        guard settings.weather.cityID == nil || cityIDs.contains(settings.weather.cityID!) else { throw AppFailure(code: .cityNotFound) }
    }
    static func metadata(_ patch: MetadataPatch, on board: BoardState, old: EventRecord?, saved: EventRecord) throws -> BoardState {
        var next = board
        if let old, old.pinKey != saved.pinKey {
            // Preserve unchanged metadata across source/calendar/occurrence identity changes.
            let pin = next.pinnedEventKeys.remove(old.pinKey) != nil
            let project = next.eventProjectLinks.removeValue(forKey: old.pinKey)
            if pin { next.pinnedEventKeys.insert(saved.pinKey) }
            if let project { next.eventProjectLinks[saved.pinKey] = project }
        }
        if case .set(let id) = patch.projectID {
            guard id == nil || next.projects.contains(where: { $0.id == id }) else { throw AppFailure(code: .unknownProject, field: .event(.projectID)) }
            next.eventProjectLinks[saved.pinKey] = id?.uuidString.lowercased()
        }
        if case .set(let pinned) = patch.pinned {
            if pinned { next.pinnedEventKeys.insert(saved.pinKey) } else { next.pinnedEventKeys.remove(saved.pinKey) }
        }
        return next
    }
}

/// Each closure captures only the changed entity/field and its precondition, never either board.
/// Operational focus/notification/budget ledgers are deliberately not part of a user inverse.
@MainActor final class NativeBoardInverse {
    private var changes: [(inout BoardState) throws -> Void] = []
    private(set) var payloadBytes = 0
    init(before: BoardState, after: BoardState) {
        field(\.notes, before: before, after: after)
        records(\.projects, before: before, after: after, id: { $0.id })
        records(\.milestones, before: before, after: after, id: { $0.id })
        records(\.subscriptions, before: before, after: after, id: { $0.id })
        records(\.todos, before: before, after: after, id: { $0.id })
        records(\.habits, before: before, after: after, id: { $0.id })
        records(\.worldClockCities, before: before, after: after, id: { $0.id })
        membership(\.pinnedEventKeys, before: before, after: after)
        membership(\.hiddenCalendarIDs, before: before, after: after)
        for key in Set(before.eventProjectLinks.keys).union(after.eventProjectLinks.keys) where before.eventProjectLinks[key] != after.eventProjectLinks[key] {
            let old = before.eventProjectLinks[key], saved = after.eventProjectLinks[key]
            changes.append { board in
                guard board.eventProjectLinks[key] == saved else { throw AppFailure(code: .boardConflict) }
                board.eventProjectLinks[key] = old
            }
        }
        field(\.layout, before: before, after: after)
        field(\.settings.desktopMode, before: before, after: after); field(\.settings.fontScale, before: before, after: after)
        field(\.settings.opacity, before: before, after: after); field(\.settings.importantOnly, before: before, after: after)
        field(\.settings.showCompletedProjects, before: before, after: after); field(\.settings.appearance, before: before, after: after)
        field(\.settings.compact, before: before, after: after); field(\.settings.language, before: before, after: after)
        field(\.settings.weekStart, before: before, after: after); field(\.settings.networkEnabled, before: before, after: after)
        field(\.settings.ratesEnabled, before: before, after: after); field(\.settings.weather, before: before, after: after)
        field(\.settings.todosCompletedCollapsed, before: before, after: after)
        field(\.settings.focus.focusSeconds, before: before, after: after); field(\.settings.focus.breakSeconds, before: before, after: after)
        field(\.settings.focus.notifyOnFinish, before: before, after: after)
    }
    func apply(to current: BoardState) throws -> BoardState {
        var next = current
        for change in changes { try change(&next) }
        try next.validate()
        return next
    }
    private func field<T: Equatable>(_ key: WritableKeyPath<BoardState, T>, before: BoardState, after: BoardState) {
        let old = before[keyPath: key], saved = after[keyPath: key]
        guard old != saved else { return }
        if let text = old as? String { payloadBytes += text.utf8.count }
        if let text = saved as? String { payloadBytes += text.utf8.count }
        changes.append { board in
            guard board[keyPath: key] == saved else { throw AppFailure(code: .boardConflict) }
            board[keyPath: key] = old
        }
    }
    private func membership(_ key: WritableKeyPath<BoardState, Set<String>>, before: BoardState, after: BoardState) {
        for value in before[keyPath: key].symmetricDifference(after[keyPath: key]) {
            let had = before[keyPath: key].contains(value), saved = after[keyPath: key].contains(value)
            changes.append { board in
                guard board[keyPath: key].contains(value) == saved else { throw AppFailure(code: .boardConflict) }
                if had { board[keyPath: key].insert(value) } else { board[keyPath: key].remove(value) }
            }
        }
    }
    private func records<T: Equatable, ID: Hashable>(_ key: WritableKeyPath<BoardState, [T]>, before: BoardState, after: BoardState,
                                                    id: @escaping (T) -> ID) {
        let original = before[keyPath: key], updated = after[keyPath: key]
        guard original != updated else { return }
        // These temporary indices bound construction to linear identity work. Only each
        // changed row and its precondition escape into the inverse, not either array/index.
        var originalIndices: [ID: Int] = [:], updatedIndices: [ID: Int] = [:]
        originalIndices.reserveCapacity(original.count); updatedIndices.reserveCapacity(updated.count)
        let originalIDs = original.map(id), updatedIDs = updated.map(id)
        for (index, identity) in originalIDs.enumerated() where originalIndices[identity] == nil { originalIndices[identity] = index }
        for (index, identity) in updatedIDs.enumerated() where updatedIndices[identity] == nil { updatedIndices[identity] = index }
        // Process deleted rows in their original order, preserving tombstone insertion indices.
        let identities = originalIDs + updatedIDs.filter { originalIndices[$0] == nil }
        for identity in identities {
            let oldIndex = originalIndices[identity]
            let old = oldIndex.map { original[$0] }, saved = updatedIndices[identity].map { updated[$0] }
            guard old != saved else { continue }
            changes.append { board in
                let currentIndex = board[keyPath: key].firstIndex { id($0) == identity }
                let current = currentIndex.map { board[keyPath: key][$0] }
                guard current == saved else { throw AppFailure(code: .boardConflict) }
                if let old {
                    if let currentIndex { board[keyPath: key][currentIndex] = old }
                    else { board[keyPath: key].insert(old, at: min(oldIndex!, board[keyPath: key].count)) }
                } else if let currentIndex { board[keyPath: key].remove(at: currentIndex) }
            }
        }
    }
}
