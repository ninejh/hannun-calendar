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
    static func results(query: String, snapshot: BoardSnapshot) -> [OverlaySearchResult] {
        let needle = query.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = TimeZone(identifier: snapshot.clock.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        func matches(_ values: [String]) -> Bool {
            needle.isEmpty || values.contains { $0.precomposedStringWithCompatibilityMapping.lowercased().contains(needle) }
        }
        // Do not filter against hiddenCalendarIDs: search is the route into hidden source events.
        var output = snapshot.calendar.records.compactMap { record -> OverlaySearchResult? in
            let day = DateOnly(date: record.item.start, timeZone: zone)
            let calendar = snapshot.calendar.calendars.first { $0.id == record.item.calendarID }
            let projectID = snapshot.board.eventProjectLinks[record.pinKey].flatMap(UUID.init(uuidString:))
            let project = snapshot.board.projects.first { $0.id == projectID }
            guard matches([record.item.title, day?.description ?? "", record.item.location, record.item.notes, calendar?.title ?? "", calendar?.account ?? "", project?.title ?? ""]) else { return nil }
            return OverlaySearchResult(id: "event." + record.id, title: record.item.title, kindKey: "search.event", day: day, target: .event(record.id))
        }
        output += snapshot.board.projects.compactMap { project in
            guard matches([project.title, project.targetDay?.description ?? ""]) else { return nil }
            return OverlaySearchResult(id: "project." + project.id.uuidString, title: project.title, kindKey: "search.project", day: project.targetDay, target: .project(project.id))
        }
        return Array(output.prefix(12))
    }
}

/// Opening identity/version stays immutable across refreshes; only explicit reload replaces it.
struct EventOverlayDraft {
    let original: EventRecord?
    var event: EventDraft
    var projectID: UUID?
    var pinned: Bool
    var metadataRetryID: String?
    var expectedVersion: String?
    var isReadOnly: Bool { original?.item.writable == false }
    var key: DraftKey { .event(original?.id ?? "new") }
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
    var savedDraft: EventEditorDraft { EventEditorDraft(event: event, metadata: MetadataPatch(projectID: .set(projectID), pinned: .set(pinned)), expectedVersion: expectedVersion) }
    mutating func restore(_ draft: EventEditorDraft) {
        event = draft.event; expectedVersion = draft.expectedVersion
        if case .set(let value) = draft.metadata.projectID { projectID = value }
        if case .set(let value) = draft.metadata.pinned { pinned = value }
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
