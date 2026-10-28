import AppKit
import Combine
import CryptoKit
@preconcurrency import EventKit

#if HANNUN_TESTING
@MainActor protocol NativeSyntheticCalendarPersistence: AnyObject {
    var nextFailure: AppFailure? { get set }
    func save(records: [EventRecord], removing: Bool) throws
}
#endif

struct EventRecord: Equatable, Sendable {
    var item: CalendarItem
    var occurrenceDate: Date?
    var lastModified: Date?
    var detached = false
    var fixtureID: String?
    var fixturePinKey: String?
    var id: String { fixtureID ?? item.id }
    var pinKey: String { fixturePinKey ?? item.pinKey }
    var serial = 0 // Fake adapter revisions; never substitutes for real EventKit preflight.
    var version: String {
        let e = item
        let parts = [e.id, e.eventIdentifier, e.title, String(e.start.timeIntervalSinceReferenceDate),
                     String(e.end.timeIntervalSinceReferenceDate), String(e.allDay), e.location, e.notes,
                     String(e.recurring), String(e.writable), String(detached),
                     occurrenceDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
                     lastModified.map { String($0.timeIntervalSinceReferenceDate) } ?? "", String(serial)]
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var draft: EventDraft {
        EventDraft(title: item.title, start: item.start, end: item.end, allDay: item.allDay,
                   calendarID: item.calendarID, location: item.location, notes: item.notes)
    }
}
struct EventDraft: Sendable {
    var title = ""
    var start = Date()
    var end = Date().addingTimeInterval(3600)
    var allDay = false
    var calendarID = ""
    var location = ""
    var notes = ""
}
struct QueryRange: Sendable, Equatable {
    var start: Date
    var end: Date
}
struct CalendarSnapshot: Sendable {
    var calendars: [CalendarInfo]
    var records: [EventRecord]
    var defaultCalendarID: String?
}

/// EKEvent, EKCalendar and the store never leave this actor.
actor CalendarWorker {
    private let store = EKEventStore()
    private var lastSourceRefresh = Date.distantPast
    private(set) var accountAccessCount = 0
    func authorization() -> (Bool, Bool) {
        let status = EKEventStore.authorizationStatus(for: .event)
        return (status == .fullAccess, status == .denied || status == .restricted || status == .writeOnly)
    }
    func requestAccess() async throws -> Bool {
        do { return try await store.requestFullAccessToEvents() }
        catch { throw NativeFailure(code: "CALENDAR_UNAVAILABLE", retryable: true) }
    }
    func snapshot(ranges: [QueryRange], refreshSources: Bool) throws -> CalendarSnapshot {
        guard authorization().0 else { throw NativeFailure(code: "CALENDAR_PERMISSION") }
        accountAccessCount += 1
        if refreshSources && Date().timeIntervalSince(lastSourceRefresh) >= 30 {
            lastSourceRefresh = Date(); store.refreshSourcesIfNecessary()
        }
        let sources = store.calendars(for: .event)
        let infos = sources.map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title,
                         colorHex: Self.hex($0.cgColor), writable: $0.allowsContentModifications)
        }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        var unique: [String: EventRecord] = [:]
        for range in ranges {
            for event in store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: sources)) where event.status != .canceled {
                let record = Self.record(event); unique[record.id] = record
            }
        }
        return CalendarSnapshot(calendars: infos, records: unique.values.sorted { $0.item.start < $1.item.start }, defaultCalendarID: store.defaultCalendarForNewEvents?.calendarIdentifier)
    }
    private func occurrence(_ original: EventRecord, requireStart: Bool = true) -> EKEvent? {
        let start = original.item.start
        let query = store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(86400), calendars: nil)
        // Never use event(withIdentifier:), which can return a series master.
        return store.events(matching: query).first {
            $0.calendar.calendarIdentifier == original.item.calendarID &&
            $0.calendarItemIdentifier == original.item.itemIdentifier &&
            (requireStart ? abs($0.startDate.timeIntervalSince(start)) < 0.001 : $0.occurrenceDate == original.occurrenceDate) && $0.status != .canceled
        }
    }
    func current(_ original: EventRecord, checkVersion: Bool) throws -> EventRecord {
        guard authorization().0 else { throw NativeFailure(code: "CALENDAR_PERMISSION") }
        store.refreshSourcesIfNecessary()
        guard let event = occurrence(original, requireStart: checkVersion) else { throw NativeFailure(code: "EVENT_NOT_FOUND") }
        let current = Self.record(event)
        if checkVersion && current.version != original.version { throw NativeFailure(code: "EVENT_CONFLICT") }
        return current
    }
    func save(_ draft: EventDraft, original: EventRecord?) throws -> EventRecord {
        guard authorization().0 else { throw NativeFailure(code: "CALENDAR_PERMISSION") }
        store.refreshSourcesIfNecessary()
        let event: EKEvent
        if let original {
            guard let fresh = occurrence(original) else { throw NativeFailure(code: "EVENT_NOT_FOUND") }
            let record = Self.record(fresh)
            guard record.version == original.version else { throw NativeFailure(code: "EVENT_CONFLICT") }
            guard fresh.calendar.allowsContentModifications else { throw NativeFailure(code: "CALENDAR_READ_ONLY") }
            guard !(record.item.recurring || record.detached) || draft.calendarID == record.item.calendarID else { throw NativeFailure(code: "RECURRING_CALENDAR_CHANGE") }
            event = fresh
        } else { event = EKEvent(eventStore: store) }
        guard let target = store.calendar(withIdentifier: draft.calendarID) else { throw NativeFailure(code: "CALENDAR_NOT_FOUND") }
        guard target.allowsContentModifications else { throw NativeFailure(code: "CALENDAR_READ_ONLY") }
        event.title = draft.title; event.startDate = draft.start; event.endDate = draft.end
        event.isAllDay = draft.allDay; event.calendar = target
        event.location = draft.location; event.notes = draft.notes
        do { try store.save(event, span: .thisEvent, commit: true) }
        catch {
            // A throwing EventKit commit is not proof of rollback. Only an unchanged refetch proves no write.
            let unchanged = original.map { old in occurrence(old).map { Self.record($0).version == old.version } ?? false } ?? false
            throw NativeFailure(code: "CALENDAR_WRITE_FAILED", committed: unchanged ? .no : .unknown)
        }
        let committed = Self.record(event)
        return occurrence(committed).map(Self.record) ?? committed
    }
    func removeCreated(_ original: EventRecord) throws {
        guard authorization().0 else { throw NativeFailure(code: "CALENDAR_PERMISSION") }
        store.refreshSourcesIfNecessary()
        guard let event = occurrence(original) else { throw NativeFailure(code: "EVENT_NOT_FOUND") }
        guard Self.record(event).version == original.version else { throw NativeFailure(code: "EVENT_CONFLICT") }
        guard event.calendar.allowsContentModifications else { throw NativeFailure(code: "CALENDAR_READ_ONLY") }
        do { try store.remove(event, span: .thisEvent, commit: true) }
        catch {
            let unchanged = occurrence(original).map { Self.record($0).version == original.version } ?? false
            throw NativeFailure(code: "CALENDAR_WRITE_FAILED", committed: unchanged ? .no : .unknown)
        }
    }
    private static func record(_ event: EKEvent) -> EventRecord {
        let item = CalendarItem(itemIdentifier: event.calendarItemIdentifier, eventIdentifier: event.eventIdentifier ?? "",
            calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
            colorHex: hex(event.calendar.cgColor), title: event.title ?? "", start: event.startDate, end: event.endDate,
            allDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "",
            recurring: event.hasRecurrenceRules || event.isDetached, writable: event.calendar.allowsContentModifications)
        return EventRecord(item: item, occurrenceDate: event.occurrenceDate, lastModified: event.lastModifiedDate, detached: event.isDetached)
    }
    private static func hex(_ color: CGColor) -> String {
        guard let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "557C68" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var records: [EventRecord] = []
    var events: [CalendarItem] { records.map(\.item) }
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var defaultCalendarID: String?
    private let worker: CalendarWorker?
    private var generation = 0
    private var retained: [String: EventRecord] = [:]
    private(set) var accountAccessCount = 0
#if HANNUN_TESTING
    var testSaveDelay = 0
    var syntheticStore: (any NativeSyntheticCalendarPersistence)?
    private var stagedSyntheticEvents: (id: UUID, records: [EventRecord])?
#endif
    let demo: Bool
    init(demo: Bool, emptyPreview: Bool = false) {
        self.demo = demo
        // Hard fence: fake modes never even construct an EKEventStore.
#if HANNUN_TESTING
        worker = nil
#else
        worker = demo ? nil : CalendarWorker()
#endif
        if demo && !emptyPreview {
            authorized = true; calendars = DemoData.calendars
            records = DemoData.events.map { EventRecord(item: $0) }
            defaultCalendarID = calendars.first?.id; refreshedAt = Date()
        }
    }
    func refresh(ranges: [QueryRange], now: Date, refreshSources: Bool = false) async {
        generation += 1; let token = generation
        loading = true
        guard let worker else { refreshedAt = now; loading = false; return }
        let access = await worker.authorization()
        guard token == generation else { return }
        authorized = access.0; denied = access.1
        guard authorized else { records = []; retained = [:]; calendars = []; defaultCalendarID = nil; error = nil; loading = false; return }
        do {
            let snapshot = try await worker.snapshot(ranges: ranges, refreshSources: refreshSources)
            guard token == generation else { return }
            calendars = snapshot.calendars; records = snapshot.records
            let loadedIDs = Set(records.map { $0.id })
            let sourceIDs = Set(calendars.map(\.id))
            retained = retained.filter { _, record in
                sourceIDs.contains(record.item.calendarID) && !ranges.contains { record.item.start < $0.end && record.item.end > $0.start }
            }
            records += retained.values.filter { !loadedIDs.contains($0.id) }
            error = nil; refreshedAt = now; defaultCalendarID = snapshot.defaultCalendarID
            accountAccessCount = await worker.accountAccessCount
        } catch {
            guard token == generation else { return }
            self.error = (error as? NativeFailure)?.code ?? "CALENDAR_UNAVAILABLE"
        }
        if token == generation { loading = false }
    }
#if HANNUN_TESTING
    @discardableResult func stageSyntheticCalendarEvents(_ records: [EventRecord]) -> Bool {
        guard demo, syntheticStore == nil else { return false }
        stagedSyntheticEvents = (UUID(), records)
        return true
    }
    func refresh(ranges: [QueryRange], now: Date, refreshSources: Bool, explicitUserRefresh: Bool) async {
        guard explicitUserRefresh, refreshSources, demo, syntheticStore == nil else {
            await refresh(ranges: ranges, now: now, refreshSources: refreshSources); return
        }
        let staged = stagedSyntheticEvents
        generation += 1; let token = generation
        loading = true
        guard authorized, error == nil, !Task.isCancelled, token == generation else { loading = false; return }
        if let staged, stagedSyntheticEvents?.id == staged.id {
            retained = [:]; records = staged.records; stagedSyntheticEvents = nil
        }
        refreshedAt = now; loading = false
    }
#endif
    func connect(ranges: [QueryRange], now: Date) async throws {
        guard let worker else { return }
        _ = try await worker.requestAccess()
        await refresh(ranges: ranges, now: now)
    }
    func find(_ id: String) -> EventRecord? { records.first { $0.id == id } ?? retained[id] }
    func current(_ original: EventRecord, checkVersion: Bool) async throws -> EventRecord {
        if let worker {
            let fresh = try await worker.current(original, checkVersion: checkVersion)
            records.removeAll { $0.id == original.id || $0.id == fresh.id }; records.append(fresh)
            retained.removeValue(forKey: original.id); retained[fresh.id] = fresh
            return fresh
        }
        guard authorized else { throw NativeFailure(code: "CALENDAR_PERMISSION") }
        guard let fresh = find(original.id) else { throw NativeFailure(code: "EVENT_NOT_FOUND") }
        guard !checkVersion || fresh.version == original.version else { throw NativeFailure(code: "EVENT_CONFLICT") }
        return fresh
    }
    func save(_ draft: EventDraft, original: EventRecord?) async throws -> EventRecord {
        generation += 1; loading = false
#if HANNUN_TESTING
        if demo && testSaveDelay > 0 { let delay = testSaveDelay; testSaveDelay = 0; try await Task.sleep(for: .milliseconds(delay)) }
#endif
        let saved: EventRecord
        if let worker { saved = try await worker.save(draft, original: original) }
        else {
            guard authorized else { throw NativeFailure(code: "CALENDAR_PERMISSION") }
            if let original {
                _ = try await current(original, checkVersion: true)
                guard original.item.writable else { throw NativeFailure(code: "CALENDAR_READ_ONLY") }
                guard !(original.item.recurring || original.detached) || draft.calendarID == original.item.calendarID else { throw NativeFailure(code: "RECURRING_CALENDAR_CHANGE") }
            }
            guard let source = calendars.first(where: { $0.id == draft.calendarID }) else { throw NativeFailure(code: "CALENDAR_NOT_FOUND") }
            guard source.writable else { throw NativeFailure(code: "CALENDAR_READ_ONLY") }
            var item = original?.item ?? CalendarItem(itemIdentifier: UUID().uuidString, eventIdentifier: UUID().uuidString,
                calendarID: source.id, calendarTitle: source.title, colorHex: source.colorHex, title: draft.title,
                start: draft.start, end: draft.end, allDay: draft.allDay, location: draft.location, notes: draft.notes, recurring: false, writable: true)
            item.calendarID = source.id; item.calendarTitle = source.title; item.colorHex = source.colorHex
            item.title = draft.title; item.start = draft.start; item.end = draft.end; item.allDay = draft.allDay
            item.location = draft.location; item.notes = draft.notes
            saved = EventRecord(item: item, occurrenceDate: original?.occurrenceDate, lastModified: original?.lastModified,
                                detached: original?.detached ?? false, fixtureID: original?.fixtureID,
                                fixturePinKey: original?.fixturePinKey, serial: (original?.serial ?? 0) + 1)
        }
        #if HANNUN_TESTING
        if let syntheticStore {
            var next = records
            if let original { next.removeAll { $0.id == original.id } }
            next.removeAll { $0.id == saved.id }; next.append(saved)
            try syntheticStore.save(records: next, removing: false)
        }
        #endif
        generation += 1
        if let original { records.removeAll { $0.id == original.id }; retained.removeValue(forKey: original.id) }
        records.removeAll { $0.id == saved.id }; records.append(saved); retained[saved.id] = saved
        return saved
    }
    func removeCreated(_ record: EventRecord) async throws {
        generation += 1; loading = false
        if let worker { try await worker.removeCreated(record) }
        else {
            let current = try await current(record, checkVersion: true)
            guard current.item.writable else { throw NativeFailure(code: "CALENDAR_READ_ONLY") }
        }
        #if HANNUN_TESTING
        if let syntheticStore { try syntheticStore.save(records: records.filter { $0.id != record.id }, removing: true) }
        #endif
        generation += 1; loading = false
        records.removeAll { $0.id == record.id }; retained.removeValue(forKey: record.id)
    }
    func readAudit(ranges: [QueryRange]) async throws -> [String: Any] {
        guard let worker else { return ["demo": true, "readOnly": true, "calendars": calendars.count, "loadedEvents": records.count, "freshEvents": records.count, "missingFromLoadedSnapshot": 0, "onlyInLoadedSnapshot": 0] }
        let fresh = try await worker.snapshot(ranges: ranges, refreshSources: true)
        accountAccessCount = await worker.accountAccessCount
        let left = Set(records.map { $0.id }), right = Set(fresh.records.map { $0.id })
        return ["demo": false, "readOnly": true, "calendars": fresh.calendars.count, "loadedEvents": left.count,
                "freshEvents": right.count, "missingFromLoadedSnapshot": right.subtracting(left).count, "onlyInLoadedSnapshot": left.subtracting(right).count]
    }
    func audit(ranges: [QueryRange]) async throws -> ReadAudit {
        guard authorized else { throw NativeFailure(code: "CALENDAR_PERMISSION") }
        guard let worker else {
            return ReadAudit(demo: true, calendars: calendars.count, loadedEvents: records.count, freshEvents: records.count,
                             missingFromLoadedSnapshot: 0, onlyInLoadedSnapshot: 0)
        }
        let fresh = try await worker.snapshot(ranges: ranges, refreshSources: true)
        accountAccessCount = await worker.accountAccessCount
        let loaded = Set(records.map(\.id)), latest = Set(fresh.records.map(\.id))
        return ReadAudit(demo: false, calendars: fresh.calendars.count, loadedEvents: loaded.count, freshEvents: latest.count,
                         missingFromLoadedSnapshot: latest.subtracting(loaded).count, onlyInLoadedSnapshot: loaded.subtracting(latest).count)
    }
#if HANNUN_TESTING
    func setFixture(calendars: [CalendarInfo], records: [EventRecord], authorization: String,
                    persistedDefault: String? = nil, restorePersistedDefault: Bool = false) {
        precondition(demo)
        self.calendars = authorization == "authorized" ? calendars : []
        self.records = authorization == "authorized" ? records : []; retained = [:]
        authorized = authorization == "authorized"; denied = authorization == "denied"
        defaultCalendarID = restorePersistedDefault ? persistedDefault : self.calendars.first(where: \.writable)?.id
    }
    func externalEdit(_ id: String, record: EventRecord?) {
        precondition(demo); records.removeAll { $0.id == id }; retained.removeValue(forKey: id)
        if let record { records.append(record) }
    }
#endif
}
