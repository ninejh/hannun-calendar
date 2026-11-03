import AppKit

enum OverlaySearchTarget: Equatable { case event(String), project(UUID) }
struct OverlaySearchResult: Equatable {
    var id: String
    var title: String
    var kindKey: String
    var day: DateOnly?
    var target: OverlaySearchTarget
}
enum OverlaySearch {
    static func results(query: String, snapshot: BoardSnapshot, limit: Int = 12) -> [OverlaySearchResult] {
        let needle = query.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = TimeZone(identifier: snapshot.clock.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        func matches(_ values: [String]) -> Bool {
            needle.isEmpty || values.contains { $0.precomposedStringWithCompatibilityMapping.lowercased().contains(needle) }
        }
        // Do not filter against hiddenCalendarIDs: search is the route into hidden source events.
        let events = snapshot.calendar.records.compactMap { record -> OverlaySearchResult? in
            let day = DateOnly(date: record.item.start, timeZone: zone)
            let calendar = snapshot.calendar.calendars.first { $0.id == record.item.calendarID }
            let projectID = snapshot.board.eventProjectLinks[record.pinKey].flatMap(UUID.init(uuidString:))
            let project = snapshot.board.projects.first { $0.id == projectID }
            guard matches([record.item.title, day?.description ?? "", record.item.location, record.item.notes, calendar?.title ?? "", calendar?.account ?? "", project?.title ?? ""]) else { return nil }
            return OverlaySearchResult(id: "event." + record.id, title: record.item.title, kindKey: "search.event", day: day, target: .event(record.id))
        }
        let projects = snapshot.board.projects.compactMap { project -> OverlaySearchResult? in
            guard matches([project.title, project.targetDay?.description ?? ""]) else { return nil }
            return OverlaySearchResult(id: "project." + project.id.uuidString, title: project.title, kindKey: "search.project", day: project.targetDay, target: .project(project.id))
        }
        let perTypeLimit = max(0, limit)
        return Array(events.prefix(perTypeLimit)) + Array(projects.prefix(perTypeLimit))
    }
}

/// Opening identity/version stays immutable across refreshes; only explicit reload replaces it.
struct EventOverlayDraft {
    let original: EventRecord?
    var keyOverride: DraftKey? = nil
    var missingSource = false
    var event: EventDraft
    var projectID: UUID?
    var pinned: Bool
    var metadataRetryID: String?
    var expectedVersion: String?
    var repeatIntervalText: String?
    var isReadOnly: Bool { missingSource || original?.item.writable == false }
    var key: DraftKey { keyOverride ?? .event(original?.id ?? "new") }
    init(record: EventRecord, snapshot: BoardSnapshot) {
        original = record; event = record.draft; expectedVersion = record.version
        projectID = snapshot.board.eventProjectLinks[record.id].flatMap(UUID.init(uuidString:))
            ?? snapshot.board.eventProjectLinks[record.pinKey].flatMap(UUID.init(uuidString:))
        pinned = snapshot.board.pinnedEventKeys.contains(record.pinKey)
    }
    init(day: DateOnly, snapshot: BoardSnapshot, projectID: UUID? = nil) {
        original = nil; self.projectID = projectID; pinned = false
        let zone = TimeZone(identifier: snapshot.clock.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let destination = snapshot.calendar.calendars.first { $0.id == snapshot.calendar.defaultCalendarID && $0.writable }
            ?? snapshot.calendar.calendars.first { $0.writable }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day.date(in: zone)) ?? day.date(in: zone)
        event = EventDraft(start: start, end: start.addingTimeInterval(3600), calendarID: destination?.id ?? "")
    }
    init(missingID: String, saved: EventEditorDraft) {
        original = nil; event = saved.event; expectedVersion = saved.expectedVersion
        keyOverride = .event(missingID); missingSource = true
        if case .set(let value) = saved.metadata.projectID { projectID = value } else { projectID = nil }
        if case .set(let value) = saved.metadata.pinned { pinned = value } else { pinned = false }
        repeatIntervalText = saved.repeatIntervalText
    }
    func externalChange(in snapshot: BoardSnapshot) -> Bool {
        guard let original else { return false }
        return snapshot.calendar.records.first { $0.id == original.id }?.version != expectedVersion
    }
    func saveInput(snapshot: BoardSnapshot) -> Result<EventSaveInput, AppFailure> {
        let metadata = MetadataPatch(projectID: .set(projectID), pinned: .set(pinned))
        if let metadataRetryID { return .success(.metadataOnly(EventIdentity(id: metadataRetryID), metadata)) }
        if let original, isReadOnly || event == original.draft { return .success(.metadataOnly(EventIdentity(id: original.id), metadata)) }
        guard event.title.count <= 500, event.location.count <= 4096, event.notes.utf8.count <= 1_048_576 else {
            return .failure(AppFailure(code: .validationFailed, messageKey: "error.validation"))
        }
        guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(AppFailure(code: .validationFailed, field: .event(.title), messageKey: "error.missing_title"))
        }
        guard event.end > event.start else { return .failure(AppFailure(code: .invalidDate, field: .event(.end), messageKey: "error.invalid_dates")) }
        if let original, original.item.recurring, event.calendarID != original.item.calendarID {
            return .failure(AppFailure(code: .recurringCalendarChange, field: .event(.calendarID), messageKey: "error.repeating_cal"))
        }
        guard snapshot.calendarAuthorization == .authorized else { return .failure(AppFailure(code: .calendarPermission, messageKey: "error.permission")) }
        guard snapshot.calendar.calendars.contains(where: { $0.id == event.calendarID && $0.writable }) else {
            return .failure(AppFailure(code: .calendarNotFound, field: .event(.calendarID), messageKey: "error.no_writable"))
        }
        if let original { return .success(.calendarEdit(EventIdentity(id: original.id), expectedVersion: expectedVersion ?? original.version, event, metadata)) }
        return .success(.calendarCreate(event, metadata))
    }
    var savedDraft: EventEditorDraft { EventEditorDraft(event: event, metadata: MetadataPatch(projectID: .set(projectID), pinned: .set(pinned)), expectedVersion: expectedVersion, repeatIntervalText: repeatIntervalText) }
    mutating func restore(_ draft: EventEditorDraft) {
        event = draft.event; expectedVersion = draft.expectedVersion; repeatIntervalText = draft.repeatIntervalText
        if case .set(let value) = draft.metadata.projectID { projectID = value }
        if case .set(let value) = draft.metadata.pinned { pinned = value }
    }
}

extension TodoEditorDraft {
    init(todo: Todo?, day: DateOnly?, projectID: UUID?) {
        self.id = todo?.id ?? UUID(); original = todo
        title = TextDraft(text: todo?.title ?? "")
        dueText = todo == nil ? (day?.description ?? "") : (todo?.dueDate?.description ?? "")
        hasDueDate = todo == nil ? day != nil : todo?.dueDate != nil
        self.projectID = todo == nil ? projectID : todo?.projectID
        frequency = todo?.recurrence?.frequency
        intervalText = String(todo?.recurrence?.interval ?? 1)
        newScheduleID = UUID()
    }
    func intent(snapshot: BoardSnapshot) -> Result<PanelIntent?, AppFailure> {
        func failure(_ key: String, code: AppFailureCode = .validationFailed) -> Result<PanelIntent?, AppFailure> {
            .failure(AppFailure(code: code, messageKey: key))
        }
        let text = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { return failure("error.empty_name") }
        let rawDate = dueText.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = hasDueDate ? DateOnly(rawDate) : nil
        guard !hasDueDate || due != nil else { return failure("todo.invalid_date") }
        guard projectID == nil || snapshot.board.projects.contains(where: { $0.id == projectID }) else { return failure("todo.project_missing") }
        if original?.recurrence != nil && due == nil { return failure("todo.repeat_clear_date") }
        var rule: TodoRecurrence?
        if let frequency {
            guard let due else { return failure("todo.repeat_date_required") }
            guard !intervalText.isEmpty, intervalText.allSatisfy(\.isNumber), let interval = Int(intervalText), (1...999).contains(interval) else { return failure("todo.repeat_interval_invalid") }
            guard original?.completed != true else { return failure("todo.repeat_completed") }
            if let previous = original?.recurrence, previous.frequency == frequency, previous.interval == interval, original?.dueDate == due {
                rule = previous
            } else { rule = TodoRecurrence(scheduleID: newScheduleID, frequency: frequency, interval: interval, anchor: due) }
        }
        guard let original else { return .success(.createTodoDetailed(TodoInput(id: id, title: text, dueDate: due, projectID: projectID, recurrence: rule))) }
        guard let current = snapshot.board.todos.first(where: { $0.id == id }) else { return failure("todo.conflict", code: .boardConflict) }
        if (text != original.title && current.title != original.title && current.title != text) ||
            (due != original.dueDate && current.dueDate != original.dueDate && current.dueDate != due) ||
            (projectID != original.projectID && current.projectID != original.projectID && current.projectID != projectID) ||
            (rule != original.recurrence && current.recurrence != original.recurrence && current.recurrence != rule) {
            return failure("todo.conflict", code: .boardConflict)
        }
        if frequency != nil && current.completed { return failure("todo.repeat_completed") }
        var patch = TodoPatch()
        if text != original.title { patch.title = text }
        if due != original.dueDate { patch.dueDate = .set(due) }
        if projectID != original.projectID { patch.projectID = .set(projectID) }
        if rule != original.recurrence { patch.recurrence = .set(rule) }
        guard patch.title != nil || due != original.dueDate || projectID != original.projectID || rule != original.recurrence else { return .success(nil) }
        return .success(.updateTodo(id, patch))
    }
}

enum OverlayPlacement {
    /// Geometry is in the board's flipped point space. Root performs screen conversion.
    static func frame(size: CGSize, anchor: CGRect?, within bounds: CGRect, previousOrigin: CGPoint? = nil) -> CGRect {
        let available = bounds.insetBy(dx: NativeSpace.sm, dy: NativeSpace.sm)
        let size = CGSize(width: min(size.width, max(0, available.width)), height: min(size.height, max(0, available.height)))
        let origin = previousOrigin ?? anchor.map { CGPoint(x: $0.minX, y: $0.maxY + NativeSpace.sm) }
            ?? CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        return NativeGeometry.clamp(CGRect(origin: origin, size: size), to: available)
    }
}
enum OverlaySettings {
    static func loginChecked(_ snapshot: BoardSnapshot) -> Bool { snapshot.login == .enabled }
    static func range(_ state: PresentationState) -> DisplayRange {
        let first = state.view.month
        return DisplayRange(month: first, visibleStart: first.addingDays(-7) ?? first,
                            endExclusive: first.addingDays(42) ?? first, selectedDay: state.view.selectedDay, mode: state.view.mode)
    }
}
