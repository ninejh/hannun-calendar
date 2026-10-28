import Foundation

struct NativeCalendarSegment: Equatable {
    var eventID: String
    var startColumn: Int
    var endColumn: Int
    var lane: Int
    var continuesBefore: Bool
    var continuesAfter: Bool
}
struct NativeCalendarWeek: Equatable { var segments: [NativeCalendarSegment] }
struct NativeCalendarPackedDay { var eventLanes: [Int]; var moreLane: Int?; var hiddenCount: Int }
struct NativeCalendarPackedWeek { var segments: [NativeCalendarSegment]; var days: [NativeCalendarPackedDay] }
enum NativeCalendarLayout {
    /// Civil ordinals keep column placement independent of the host zone and 23/25-hour days.
    static func days(month: DateOnly, selected: DateOnly, mode: DisplayMode, weekStart: Int) -> [DateOnly?] {
        guard (1...7).contains(weekStart) else { return [] }
        let first = mode == .week ? selected : DateOnly(String(format: "%04d-%02d-01", month.year, month.month))!
        let weekday = first.ordinal % 7 + 1
        let offset = (weekday - weekStart + 7) % 7
        let count: Int
        if mode == .week { count = 7 }
        else {
            let next = month.month == 12 ? String(format: "%04d-01-01", month.year + 1) : String(format: "%04d-%02d-01", month.year, month.month + 1)
            let length = DateOnly(next).map { $0.ordinal - first.ordinal } ?? 31
            count = max(35, ((offset + length + 6) / 7) * 7)
        }
        return (0..<count).map { first.addingDays($0 - offset) }
    }
    static func eventDays(_ record: EventRecord, timeZone: TimeZone) -> ClosedRange<DateOnly>? {
        let item = record.item
        guard item.start.timeIntervalSinceReferenceDate.isFinite, item.end.timeIntervalSinceReferenceDate.isFinite,
              let first = DateOnly(date: item.start, timeZone: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let end = DayMath.inclusiveEndDay(start: item.start, end: item.end, calendar: calendar)
        guard let last = DateOnly(date: end, timeZone: timeZone) else { return nil }
        return first...max(first, last)
    }
    static func weeks(records: [EventRecord], days: [DateOnly?], timeZone: TimeZone) -> [NativeCalendarWeek] {
        let spanning = records.compactMap { record -> (String, ClosedRange<DateOnly>)? in
            guard let range = eventDays(record, timeZone: timeZone), range.lowerBound < range.upperBound else { return nil }
            return (record.id, range)
        }
        var preferred: [String: Int] = [:], result: [NativeCalendarWeek] = []
        for offset in stride(from: 0, to: days.count, by: 7) {
            let slice = Array(days[offset..<min(days.count, offset + 7)])
            guard let first = slice.compactMap({ $0 }).first, let last = slice.compactMap({ $0 }).last else { result.append(NativeCalendarWeek(segments: [])); continue }
            var candidates = spanning.compactMap { id, range -> NativeCalendarSegment? in
                guard range.lowerBound <= last, range.upperBound >= first else { return nil }
                let start = slice.firstIndex { $0.map { $0 >= range.lowerBound } ?? false } ?? 0
                let end = slice.lastIndex { $0.map { $0 <= range.upperBound } ?? false } ?? (slice.count - 1)
                return NativeCalendarSegment(eventID: id, startColumn: start, endColumn: end, lane: 0, continuesBefore: range.lowerBound < first, continuesAfter: range.upperBound > last)
            }
            candidates.sort {
                if (preferred[$0.eventID] != nil) != (preferred[$1.eventID] != nil) { return preferred[$0.eventID] != nil }
                if $0.startColumn != $1.startColumn { return $0.startColumn < $1.startColumn }
                if $0.endColumn != $1.endColumn { return $0.endColumn > $1.endColumn }
                return $0.eventID < $1.eventID
            }
            var occupied: [Int: Int] = [:]
            for index in candidates.indices {
                let candidate = candidates[index], mask = ((1 << (candidate.endColumn - candidate.startColumn + 1)) - 1) << candidate.startColumn
                var lane = preferred[candidate.eventID] ?? 0
                if (occupied[lane, default: 0] & mask) != 0 { lane = 0 }
                while (occupied[lane, default: 0] & mask) != 0 { lane += 1 }
                occupied[lane, default: 0] |= mask; candidates[index].lane = lane
            }
            preferred = Dictionary(uniqueKeysWithValues: candidates.filter(\.continuesAfter).map { ($0.eventID, $0.lane) })
            result.append(NativeCalendarWeek(segments: candidates))
        }
        return result
    }
    static func pack(_ week: NativeCalendarWeek, dailyCounts: [Int], capacity: Int) -> NativeCalendarPackedWeek {
        let capacity = max(0, capacity)
        var visible = Set(week.segments.filter { $0.lane < capacity }.map(\.eventID))
        func column(_ index: Int) -> (free: [Int], hidden: Int, needsMore: Bool) {
            let covering = week.segments.filter { $0.startColumn <= index && $0.endColumn >= index }
            let occupied = Set(covering.filter { visible.contains($0.eventID) }.map(\.lane))
            let free = (0..<capacity).filter { !occupied.contains($0) }
            let hidden = covering.filter { !visible.contains($0.eventID) }.count
            return (free, hidden, hidden > 0 || dailyCounts[index] > free.count)
        }
        for index in dailyCounts.indices {
            let state = column(index)
            if capacity > 0, state.free.isEmpty, state.needsMore,
               let displaced = week.segments.filter({ $0.startColumn <= index && $0.endColumn >= index && visible.contains($0.eventID) }).max(by: { $0.lane < $1.lane }) {
                visible.remove(displaced.eventID)
            }
        }
        let packed = dailyCounts.indices.map { index in
            let state = column(index)
            var free = state.free
            let more = state.needsMore ? free.popLast() : nil
            let lanes = Array(free.prefix(max(0, dailyCounts[index])))
            return NativeCalendarPackedDay(eventLanes: lanes, moreLane: more, hiddenCount: state.hidden + dailyCounts[index] - lanes.count)
        }
        return NativeCalendarPackedWeek(segments: week.segments.filter { visible.contains($0.eventID) }, days: packed)
    }
    static func shift(_ record: EventRecord, to target: DateOnly, timeZone: TimeZone) -> EventDraft? {
        guard let original = DateOnly(date: record.item.start, timeZone: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let delta = target.ordinal - original.ordinal
        guard let start = calendar.date(byAdding: .day, value: delta, to: record.item.start),
              let end = calendar.date(byAdding: .day, value: delta, to: record.item.end), end >= start else { return nil }
        var draft = record.draft; draft.start = start; draft.end = end; return draft
    }
}
