import Foundation

/// Optimistic event values only. Real identity/version/preflight and durable compensation stay native.
enum EventPreview {
    static func apply(_ input: EventSaveInput, operationID: UUID, to snapshot: inout BoardSnapshot) {
        switch input {
        case .calendarCreate(let draft, let metadata):
            let temporary = "pending:" + operationID.uuidString.lowercased()
            guard !snapshot.calendar.records.contains(where: { $0.item.itemIdentifier == temporary }) else { return }
            let calendarID = draft.calendarID.isEmpty ? snapshot.calendar.defaultCalendarID ?? "" : draft.calendarID
            let source = snapshot.calendar.calendars.first { $0.id == calendarID }
            let item = CalendarItem(itemIdentifier: temporary, eventIdentifier: temporary, calendarID: calendarID,
                                    calendarTitle: source?.title ?? "", colorHex: source?.colorHex ?? "557C68",
                                    title: draft.title, start: draft.start, end: draft.end, allDay: draft.allDay,
                                    location: draft.location, notes: draft.notes, recurring: false, writable: source?.writable ?? true)
            snapshot.calendar.records.append(EventRecord(item: item)); apply(metadata, pinKey: item.pinKey, board: &snapshot.board)
        case .calendarEdit(let identity, _, let draft, let metadata):
            guard let index = snapshot.calendar.records.firstIndex(where: { $0.id == identity.id }), snapshot.calendar.records[index].item.writable else { return }
            var item = snapshot.calendar.records[index].item
            let calendarID = draft.calendarID.isEmpty ? item.calendarID : draft.calendarID
            guard !item.recurring || calendarID == item.calendarID else { return }
            item.calendarID = calendarID
            if let source = snapshot.calendar.calendars.first(where: { $0.id == calendarID }) { item.calendarTitle = source.title; item.colorHex = source.colorHex }
            item.title = draft.title; item.start = draft.start; item.end = draft.end; item.allDay = draft.allDay
            item.location = draft.location; item.notes = draft.notes
            snapshot.calendar.records[index].item = item; apply(metadata, pinKey: item.pinKey, board: &snapshot.board)
        case .metadataOnly(let identity, let metadata):
            guard let event = snapshot.calendar.records.first(where: { $0.id == identity.id }) else { return }
            apply(metadata, pinKey: event.pinKey, board: &snapshot.board)
        }
    }
    private static func apply(_ metadata: MetadataPatch, pinKey: String, board: inout BoardState) {
        if case .set(let project) = metadata.projectID { board.eventProjectLinks[pinKey] = project?.uuidString.lowercased() }
        if case .set(let pinned) = metadata.pinned {
            if pinned { board.pinnedEventKeys.insert(pinKey) } else { board.pinnedEventKeys.remove(pinKey) }
        }
    }
}
struct EventPreviewInverse {
    var before: EventRecord?
    var after: EventRecord
    var index: Int
    init?(input: EventSaveInput, operationID: UUID, before: CalendarSnapshot, after: CalendarSnapshot) {
        switch input {
        case .calendarCreate:
            guard let value = after.records.first(where: { $0.item.itemIdentifier == "pending:" + operationID.uuidString.lowercased() }) else { return nil }
            self.before = nil; self.after = value; index = before.records.count
        case .calendarEdit(let identity, _, _, _):
            guard let index = before.records.firstIndex(where: { $0.id == identity.id }), after.records.indices.contains(index) else { return nil }
            self.before = before.records[index]; self.after = after.records[index]; self.index = index
        case .metadataOnly: return nil
        }
    }
    func apply(to calendar: inout CalendarSnapshot) {
        guard let current = calendar.records.firstIndex(where: { $0.id == after.id }), calendar.records[current] == after else { return }
        calendar.records.remove(at: current)
        if let before { calendar.records.insert(before, at: min(index, calendar.records.count)) }
    }
}
