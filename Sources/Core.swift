import Foundation
import CryptoKit

struct NativeStrings: Sendable {
    let dictionaries: [String: [String: String]]
    init(dictionaries: [String: [String: String]]) { self.dictionaries = dictionaries }
    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "Strings", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let maps = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            dictionaries = maps
        } else { dictionaries = [:] }
    }
    func text(_ key: String, language: String, values: [String: String] = [:]) -> String {
        let fallback = dictionaries["en"]?["error.generic"] ?? "Something went wrong. Please try again."
        guard let english = dictionaries["en"]?[key], !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        let translated = language == "ko" ? dictionaries["ko"]?[key] : nil
        let source = translated.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? english
        let regex = try! NSRegularExpression(pattern: "\\{([A-Za-z0-9_]+)\\}")
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard matches.allSatisfy({ values[(source as NSString).substring(with: $0.range(at: 1))] != nil }) else { return fallback }
        var result = source
        // Reverse original ranges: inserted values are literal and never reparsed.
        for match in matches.reversed() {
            let name = (source as NSString).substring(with: match.range(at: 1))
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: values[name]!) }
        }
        return result
    }
}


enum DayMath {
    static var calendar: Calendar {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { DateEnvironmentCache.calendar(timeZone: .current) }
        }
        return makeCalendar(timeZone: .current)
    }

    fileprivate static func makeCalendar(timeZone: TimeZone) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US")
        value.timeZone = timeZone
        value.firstWeekday = 1
        return value
    }

    static func monthStart(_ date: Date, calendar: Calendar = calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }

    static func gridDays(for date: Date, calendar: Calendar = calendar) -> [Date] {
        let start = monthStart(date, calendar: calendar)
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        let slots = max(35, ((count + offset + 6) / 7) * 7)
        let first = calendar.date(byAdding: .day, value: -offset, to: start)!
        return (0..<slots).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }

    static func daysUntil(_ target: Date, from now: Date = Date(), calendar: Calendar = calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
    }

    static func countdown(_ target: Date, from now: Date = Date(), calendar: Calendar = calendar) -> String {
        let days = daysUntil(target, from: now, calendar: calendar)
        return days == 0 ? "D-Day" : days > 0 ? "D-\(days)" : "D+\(-days)"
    }

    static func intersects(start: Date, end: Date, day: Date, calendar: Calendar = calendar) -> Bool {
        let lower = calendar.startOfDay(for: day)
        let upper = calendar.date(byAdding: .day, value: 1, to: lower)!
        if start == end { return start >= lower && start < upper }
        return start < upper && end > lower
    }

    /// The final calendar day touched by a half-open event interval.
    /// Imported all-day events may end late on their final day instead of at the next midnight.
    static func inclusiveEndDay(start: Date, end: Date, calendar: Calendar = calendar) -> Date {
        let first = calendar.startOfDay(for: start)
        guard end > start else { return first }
        return max(first, calendar.startOfDay(for: end.addingTimeInterval(-0.001)))
    }

    static func text(_ date: Date, format: String, timeZone: TimeZone = .current,
                     locale: Locale = Locale(identifier: "en_US")) -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                DateEnvironmentCache.text(date, format: format, timeZone: timeZone, locale: locale)
            }
        }
        // Worker actors use a local formatter; non-Sendable formatter instances never cross actors.
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = makeCalendar(timeZone: timeZone)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func eventCount(_ count: Int) -> String { count == 1 ? "1 event" : "\(count) events" }
}

@MainActor
private enum DateEnvironmentCache {
    private static var environment = ""
    private static var cachedCalendar = DayMath.makeCalendar(timeZone: .current)
    private static var formatters: [String: DateFormatter] = [:]

    private static func update(timeZone: TimeZone, locale: Locale) {
        let key = timeZone.identifier + "|" + locale.identifier + "|" + Locale.current.identifier
        guard environment != key else { return }
        environment = key
        cachedCalendar = DayMath.makeCalendar(timeZone: timeZone)
        formatters.removeAll()
    }
    static func calendar(timeZone: TimeZone) -> Calendar {
        update(timeZone: timeZone, locale: Locale(identifier: "en_US"))
        return cachedCalendar
    }
    static func text(_ date: Date, format: String, timeZone: TimeZone, locale: Locale) -> String {
        update(timeZone: timeZone, locale: locale)
        let formatter: DateFormatter
        if let cached = formatters[format] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = locale; formatter.calendar = cachedCalendar
            formatter.timeZone = timeZone; formatter.dateFormat = format
            formatters[format] = formatter
        }
        return formatter.string(from: date)
    }
}

struct CalendarInfo: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var account: String
    var colorHex: String
    var writable: Bool
}

struct CalendarItem: Identifiable, Equatable, Sendable {
    var itemIdentifier: String
    var eventIdentifier: String
    var calendarID: String
    var calendarTitle: String
    var colorHex: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    var notes: String
    var recurring: Bool
    var writable: Bool
    var id: String { "\(calendarID)|\(itemIdentifier)|\(start.timeIntervalSinceReferenceDate)" }
    // The calendar identity is sufficient for a non-recurring event; a recurring pin is per occurrence.
    var pinKey: String { recurring ? id : "\(calendarID)|\(itemIdentifier)" }
    func occurs(on day: Date) -> Bool { DayMath.intersects(start: start, end: end, day: day) }
    var timeLabel: String { allDay ? "All day" : DayMath.text(start, format: "HH:mm") }
}

/// Gregorian civil date. Persistence never passes through an instant or the host time zone.
struct DateOnly: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else { return nil }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) } }
        let y = number(0..<4), m = number(5..<7), d = number(8..<10)
        guard (1...9999).contains(y), (1...12).contains(m) else { return nil }
        let lengths = [31, Self.leap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...lengths[m - 1]).contains(d) else { return nil }
        year = y; month = m; day = d
    }

    init?(date: Date, timeZone: TimeZone = .current) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
        self.init(String(format: "%04d-%02d-%02d", y, m, d))
    }

    private static func leap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }
    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var ordinal: Int {
        let previous = year - 1
        let beforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][month - 1]
        return previous * 365 + previous / 4 - previous / 100 + previous / 400 + beforeMonth + day
            + (month > 2 && Self.leap(year) ? 1 : 0)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }

    /// Only the old bridge's display accessor uses Date; the stored value stays civil.
    func date(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(era: 1, year: year, month: month, day: day, hour: 12))!
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(try container.decode(String.self)) else { throw BoardStorageError(.invalidData) }
        self = value
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

private struct AnyBoardKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Unsupported extension data is protected, rather than passed through a lossy JSON number conversion.
func requireKnownFields(_ decoder: Decoder, _ names: [String]) throws {
    let container = try decoder.container(keyedBy: AnyBoardKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: Set(names)) else {
        throw BoardStorageError(.protectedData)
    }
}

private func validColor(_ value: String, fallback: String) -> String {
    let bytes = Array(value.utf8)
    return bytes.count == 6 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        ? value.uppercased() : fallback
}

struct Milestone: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var day: DateOnly
    var colorHex: String
    var date: Date {
        get { day.date() }
        set { if let value = DateOnly(date: newValue) { day = value } }
    }
    init(id: UUID = UUID(), title: String, date: Date, colorHex: String = "D46E48") {
        self.id = id; self.title = title; self.day = DateOnly(date: date)!; self.colorHex = colorHex
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, date, colorHex }
    init(from decoder: Decoder) throws { try self.init(from: decoder, legacy: false) }
    fileprivate init(from decoder: Decoder, legacy: Bool) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        if legacy {
            guard let value = DateOnly(date: try c.decode(Date.self, forKey: .date)) else { throw BoardStorageError(.invalidData) }
            day = value
        } else { day = try c.decode(DateOnly.self, forKey: .date) }
        colorHex = validColor((try? c.decode(String.self, forKey: .colorHex)) ?? "D46E48", fallback: "D46E48")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(day, forKey: .date); try c.encode(colorHex, forKey: .colorHex)
    }
}

private struct LegacyMilestone: Decodable {
    let value: Milestone
    init(from decoder: Decoder) throws { value = try Milestone(from: decoder, legacy: true) }
}

enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case active, waiting, done
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "active", "In progress", "진행 중": self = .active
        case "waiting", "On hold", "잠시 대기": self = .waiting
        case "done", "Done", "완료": self = .done
        default: throw BoardStorageError(.invalidData)
        }
    }
}

struct Project: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var focus: String
    var nextStep: String
    var status: ProjectStatus
    var targetDay: DateOnly?
    var colorHex: String
    var progress: Int
    var targetDate: Date? {
        get { targetDay?.date() }
        set { targetDay = newValue.flatMap { DateOnly(date: $0) } }
    }
    init(id: UUID = UUID(), title: String, focus: String = "", nextStep: String = "", status: ProjectStatus = .active,
         targetDate: Date? = nil, colorHex: String = "557C68", progress: Int = 0) {
        self.id = id; self.title = title; self.focus = focus; self.nextStep = nextStep; self.status = status
        targetDay = targetDate.flatMap { DateOnly(date: $0) }; self.colorHex = colorHex; self.progress = progress
    }
    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, focus, nextStep, status, targetDate, colorHex, progress }
    init(from decoder: Decoder) throws { try self.init(from: decoder, legacy: false) }
    fileprivate init(from decoder: Decoder, legacy: Bool) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        focus = try c.decodeIfPresent(String.self, forKey: .focus) ?? ""
        nextStep = try c.decodeIfPresent(String.self, forKey: .nextStep) ?? ""
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status) ?? .active
        if legacy {
            if let date = try c.decodeIfPresent(Date.self, forKey: .targetDate) {
                guard let value = DateOnly(date: date) else { throw BoardStorageError(.invalidData) }
                targetDay = value
            } else { targetDay = nil }
        } else { targetDay = try c.decodeIfPresent(DateOnly.self, forKey: .targetDate) }
        colorHex = validColor((try? c.decode(String.self, forKey: .colorHex)) ?? "98C8B2", fallback: "98C8B2")
        progress = min(100, max(0, try c.decodeIfPresent(Int.self, forKey: .progress) ?? 0))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(focus, forKey: .focus); try c.encode(nextStep, forKey: .nextStep); try c.encode(status, forKey: .status)
        try c.encode(targetDay, forKey: .targetDate); try c.encode(colorHex, forKey: .colorHex); try c.encode(progress, forKey: .progress)
    }
}

private struct LegacyProject: Decodable {
    let value: Project
    init(from decoder: Decoder) throws { value = try Project(from: decoder, legacy: true) }
}

enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "system", "System", "시스템": self = .system
        case "light", "Light", "라이트": self = .light
        case "dark", "Dark", "다크": self = .dark
        default: throw BoardStorageError(.invalidData)
        }
    }
}

enum BoardLanguage: String, Codable, Sendable { case en, ko }
enum WeekStart: String, Codable, Sendable { case system, sunday, monday }

extension CodingUserInfoKey {
    static let boardDefaultWeatherCityID = CodingUserInfoKey(rawValue: "boardDefaultWeatherCityID")!
}

struct BoardSettings: Codable, Equatable, Sendable {
    var desktopMode = true
    var fontScale = 1.1
    var opacity = 1.0
    var importantOnly = true
    var showCompletedProjects = false
    var appearance: AppAppearance = .dark
    var compact = true
    var language: BoardLanguage = .en
    var weekStart: WeekStart = .system
    var networkEnabled = true
    var ratesEnabled = true
    var weather = WeatherSettings()
    var todosCompletedCollapsed = false
    var focus = FocusSettings()
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case desktopMode, fontScale, opacity, importantOnly, showCompletedProjects, appearance, compact, language, weekStart
        case networkEnabled, ratesEnabled, weather, todosCompletedCollapsed, focus
    }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        desktopMode = (try? c.decode(Bool.self, forKey: .desktopMode)) ?? true
        let scale = (try? c.decode(Double.self, forKey: .fontScale)) ?? 1.1
        fontScale = scale.isFinite ? min(1.5, max(0.9, scale)) : 1.1
        let alpha = (try? c.decode(Double.self, forKey: .opacity)) ?? 1.0
        opacity = alpha.isFinite ? min(1, max(0.75, alpha)) : 1
        importantOnly = (try? c.decode(Bool.self, forKey: .importantOnly)) ?? true
        showCompletedProjects = (try? c.decode(Bool.self, forKey: .showCompletedProjects)) ?? false
        appearance = (try? c.decode(AppAppearance.self, forKey: .appearance)) ?? .dark
        compact = (try? c.decode(Bool.self, forKey: .compact)) ?? true
        language = (try? c.decode(BoardLanguage.self, forKey: .language)) ?? .en
        weekStart = (try? c.decode(WeekStart.self, forKey: .weekStart)) ?? .system
        networkEnabled = (try? c.decode(Bool.self, forKey: .networkEnabled)) ?? true
        ratesEnabled = (try? c.decode(Bool.self, forKey: .ratesEnabled)) ?? true
        weather = try c.decodeIfPresent(WeatherSettings.self, forKey: .weather) ?? WeatherSettings(cityID: decoder.userInfo[.boardDefaultWeatherCityID] as? String)
        todosCompletedCollapsed = (try? c.decode(Bool.self, forKey: .todosCompletedCollapsed)) ?? false
        focus = try c.decodeIfPresent(FocusSettings.self, forKey: .focus) ?? FocusSettings()
    }
}

enum SlotID: String, Codable, CaseIterable, Sendable { case wide, railTop, railMiddle, railBottom }
enum PanelID: String, Codable, CaseIterable, Sendable {
    case today, deadlines, projects, notes, subscriptions, todos, habits, worldClock, focusTimer
}

enum PanelSizeStep: Int, Codable, Sendable, CaseIterable { case tiny = 1, small, regular, large }
enum LayoutSplit: String, Sendable, CaseIterable { case column, main, rail, railBottom }
struct LayoutViewport: Sendable, Equatable {
    let width: Double
    let height: Double
}

/// Values used on screen. The five persisted preferences remain integers in BoardLayout.
struct LayoutSteps: Equatable, Sendable {
    var column: PanelSizeStep = .regular
    var main: PanelSizeStep = .regular
    var railTop: PanelSizeStep = .regular
    var railMiddle: PanelSizeStep = .regular
    var railBottom: PanelSizeStep = .regular
    subscript(_ slot: SlotID) -> PanelSizeStep {
        get { switch slot { case .wide: main; case .railTop: railTop; case .railMiddle: railMiddle; case .railBottom: railBottom } }
        set { switch slot { case .wide: main = newValue; case .railTop: railTop = newValue; case .railMiddle: railMiddle = newValue; case .railBottom: railBottom = newValue } }
    }
    subscript(_ split: LayoutSplit) -> PanelSizeStep {
        get { switch split { case .column: column; case .main: main; case .rail: railTop; case .railBottom: railBottom } }
        set { switch split { case .column: column = newValue; case .main: main = newValue; case .rail: railTop = newValue; case .railBottom: railBottom = newValue } }
    }
}

/// D-86/D-90 logical point dimensions. No rounding, AppKit objects, caches, or I/O.
struct PanelStepProfile: Equatable, Sendable {
    static let padding = 16.0, gap = 14.0, tolerance = 1e-7
    let viewport: LayoutViewport
    let contentWidth: Double
    let contentHeight: Double
    let columnWidths: [Double]
    let wideHeights: [Double]
    let railTopHeights: [Double]
    let railMiddleHeights: [Double]
    let railBottomHeights: [Double]

    init(viewport: LayoutViewport) throws {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw BoardStorageError(.invalidData)
        }
        self.viewport = viewport
        contentWidth = viewport.width - 32; contentHeight = viewport.height - 32
        let r = min(430, max(320, viewport.width / 4))
        let b = viewport.width <= 1350 ? 234 : min(280, max(248, viewport.height * 0.24))
        let t = (contentHeight - b - 28) * 1.08 / 2.08
        let m = (contentHeight - b - 28) / 2.08, s = (m - 160) / 2
        columnWidths = [280, (280 + r) / 2, r, min(r + (r - 280) / 2, contentWidth - 14 - 600)]
        wideHeights = [104, (104 + b) / 2, b, min(b + (b - 104) / 2, contentHeight - 14 - 420)]
        railTopHeights = [160, (160 + t) / 2, t, t + s]
        railMiddleHeights = [160, (160 + m) / 2, m, m + (m - 160) / 2]
        railBottomHeights = [90, (90 + b) / 2, b, b + s]
        let lists = [columnWidths, wideHeights, railTopHeights, railMiddleHeights, railBottomHeights]
        guard lists.allSatisfy({ values in zip(values, values.dropFirst()).allSatisfy { $0 + Self.tolerance < $1 } }),
              contentWidth - 14 - columnWidths[3] >= 600 - Self.tolerance,
              contentHeight - 14 - wideHeights[3] >= 420 - Self.tolerance,
              abs(railTopHeights[3] + 160 + railBottomHeights[3] + 28 - contentHeight) <= Self.tolerance else {
            throw BoardStorageError(.invalidData)
        }
    }
    func railWidth(_ step: PanelSizeStep) -> Double { columnWidths[step.rawValue - 1] }
    func height(_ slot: SlotID, step: PanelSizeStep) -> Double {
        let values: [Double] = switch slot {
        case .wide: wideHeights; case .railTop: railTopHeights; case .railMiddle: railMiddleHeights; case .railBottom: railBottomHeights
        }
        return values[step.rawValue - 1]
    }
    func visibleRailSlots(hiddenSlots: Set<String>) -> [SlotID] {
        [.railTop, .railMiddle, .railBottom].filter { !hiddenSlots.contains($0.rawValue) }
    }
    func railBlankHeight(steps: LayoutSteps, hiddenSlots: Set<String>) -> Double {
        let slots = visibleRailSlots(hiddenSlots: hiddenSlots)
        return contentHeight - slots.reduce(0) { $0 + height($1, step: steps[$1]) } - Self.gap * Double(max(0, slots.count - 1))
    }
    func railFits(steps: LayoutSteps, hiddenSlots: Set<String>) -> Bool {
        railBlankHeight(steps: steps, hiddenSlots: hiddenSlots) >= -Self.tolerance
    }
    func dividerPosition(_ split: LayoutSplit, steps: LayoutSteps) -> Double {
        switch split {
        case .column: Self.padding + contentWidth - railWidth(steps.column) - Self.gap / 2
        case .main: Self.padding + contentHeight - height(.wide, step: steps.main) - Self.gap / 2
        case .rail: Self.padding + height(.railTop, step: steps.railTop) + Self.gap / 2
        case .railBottom: Self.padding + contentHeight - height(.railBottom, step: steps.railBottom) - Self.gap / 2
        }
    }
}

struct LayoutStepCandidate: Equatable, Sendable {
    let step: PanelSizeStep
    let steps: LayoutSteps
    /// Pair-only patch applied to original preferences; hidden/third preferences survive ACK.
    let layout: BoardLayout
    let primarySlot: SlotID?
    let neighborSlot: SlotID?
    let dividerPosition: Double
}

enum LayoutStepResolver {
    static func effectiveSteps(layout: BoardLayout, profile: PanelStepProfile) throws -> LayoutSteps {
        try layout.validate()
        var result = layout.steps
        if !layout.hiddenSlots.contains("railMiddle") {
            while !profile.railFits(steps: result, hiddenSlots: layout.hiddenSlots), result.railMiddle != .tiny {
                result.railMiddle = PanelSizeStep(rawValue: result.railMiddle.rawValue - 1)!
            }
        }
        guard profile.railFits(steps: result, hiddenSlots: layout.hiddenSlots) else { throw BoardStorageError(.invalidData) }
        return result
    }
    static func candidates(layout: BoardLayout, split: LayoutSplit, viewport: LayoutViewport) throws -> [LayoutStepCandidate] {
        let profile = try PanelStepProfile(viewport: viewport)
        let start = try effectiveSteps(layout: layout, profile: profile)
        let visible = profile.visibleRailSlots(hiddenSlots: layout.hiddenSlots)
        let primary: SlotID?, neighbor: SlotID?
        switch split {
        case .column:
            guard !visible.isEmpty else { throw BoardStorageError(.invalidData) }
            primary = nil; neighbor = nil
        case .main:
            guard !layout.hiddenSlots.contains("wide") else { throw BoardStorageError(.invalidData) }
            primary = .wide; neighbor = nil
        case .rail:
            guard visible.contains(.railTop), visible.contains(.railMiddle) else { throw BoardStorageError(.invalidData) }
            primary = .railTop; neighbor = .railMiddle
        case .railBottom:
            guard visible.contains(.railBottom), visible.count > 1 else { throw BoardStorageError(.invalidData) }
            primary = .railBottom; neighbor = visible.contains(.railMiddle) ? .railMiddle : .railTop
        }
        return try PanelSizeStep.allCases.map { step in
            var steps = start, candidate = layout
            if step != start[split] {
                steps[split] = step
                candidate.setStep(split, step)
                if let neighbor {
                    guard let fit = PanelSizeStep.allCases.reversed().first(where: { value in
                        var trial = steps; trial[neighbor] = value
                        return profile.railFits(steps: trial, hiddenSlots: layout.hiddenSlots)
                    }) else { throw BoardStorageError(.invalidData) }
                    steps[neighbor] = fit; candidate.setHeightStep(neighbor, fit)
                }
            }
            guard profile.railFits(steps: steps, hiddenSlots: layout.hiddenSlots) else { throw BoardStorageError(.invalidData) }
            return LayoutStepCandidate(step: step, steps: steps, layout: candidate, primarySlot: primary,
                                       neighborSlot: neighbor, dividerPosition: profile.dividerPosition(split, steps: steps))
        }
    }
    static func resolve(layout: BoardLayout, split: LayoutSplit, step: PanelSizeStep, viewport: LayoutViewport) throws -> BoardLayout {
        try candidates(layout: layout, split: split, viewport: viewport)[step.rawValue - 1].layout
    }
    static func nearest(_ candidates: [LayoutStepCandidate], pointer: Double, grabOffset: Double = 0) throws -> LayoutStepCandidate {
        guard pointer.isFinite, grabOffset.isFinite, (pointer - grabOffset).isFinite, candidates.count == 4 else {
            throw BoardStorageError(.invalidData)
        }
        return candidates.min { a, b in
            let da = abs(a.dividerPosition - (pointer - grabOffset)), db = abs(b.dividerPosition - (pointer - grabOffset))
            return abs(da - db) <= PanelStepProfile.tolerance ? a.step.rawValue < b.step.rawValue : da < db
        }!
    }
}

extension CodingUserInfoKey {
    static let layoutViewport = CodingUserInfoKey(rawValue: "layoutViewport")!
}

/// Migration uses the all-visible legacy layout, independently of stored hidden slots.
private struct LegacyLayoutSplits {
    enum Scalar {
        case automatic, damaged, ratio(Double)
        var value: Double? { if case .ratio(let value) = self { value } else { nil } }
        var damaged: Bool { if case .damaged = self { true } else { false } }
    }
    let column: Scalar, main: Scalar, rail: Scalar, railBottom: Scalar
    var hasRatio: Bool { [column, main, rail, railBottom].contains { $0.value != nil } }
    func nearest(profile: PanelStepProfile) throws -> LayoutSteps {
        let width = profile.contentWidth, height = profile.contentHeight
        func size(_ scalar: Scalar, total: Double, minimum: Double, otherMinimum: Double, automatic: Double) -> Double {
            min(total - otherMinimum, max(minimum, scalar.value.map { $0 * total } ?? automatic))
        }
        func nearest(_ value: Double, values: [Double]) -> PanelSizeStep {
            var best = 0
            for i in 1..<4 where abs(values[i] - value) < abs(values[best] - value) - PanelStepProfile.tolerance { best = i }
            return PanelSizeStep(rawValue: best + 1)!
        }
        var result = LayoutSteps()
        if column.value != nil {
            let left = size(column, total: width - 14, minimum: 600, otherMinimum: 280, automatic: width - 14 - profile.columnWidths[2])
            result.column = nearest(width - 14 - left, values: profile.columnWidths)
        }
        if main.value != nil {
            let calendar = size(main, total: height - 14, minimum: 420, otherMinimum: 104, automatic: height - 14 - profile.wideHeights[2])
            result.main = nearest(height - 14 - calendar, values: profile.wideHeights)
        }
        guard !rail.damaged, !railBottom.damaged, rail.value != nil || railBottom.value != nil else { return result }
        let upper = size(railBottom, total: height - 14, minimum: 334, otherMinimum: 90, automatic: height - 14 - profile.railBottomHeights[2])
        let top = size(rail, total: upper - 14, minimum: 160, otherMinimum: 160, automatic: (upper - 14) * 1.08 / 2.08)
        let middle = upper - 14 - top, bottom = height - 14 - upper
        var bestDistance = Double.infinity
        for t in PanelSizeStep.allCases { for m in PanelSizeStep.allCases { for b in PanelSizeStep.allCases {
            var candidate = result; candidate.railTop = t; candidate.railMiddle = m; candidate.railBottom = b
            guard profile.railFits(steps: candidate, hiddenSlots: []) else { continue }
            let distance = abs(profile.height(.railTop, step: t) - top) + abs(profile.height(.railMiddle, step: m) - middle)
                + abs(profile.height(.railBottom, step: b) - bottom)
            if distance < bestDistance - PanelStepProfile.tolerance { result = candidate; bestDistance = distance }
        } } }
        guard bestDistance.isFinite else { throw BoardStorageError(.invalidData) }
        return result
    }
}

enum GridItemID: String, Codable, CaseIterable, Sendable { case calendar, wide, railTop, railMiddle, railBottom }
struct GridRect: Codable, Equatable, Sendable {
    let column: Int, row: Int, width: Int, height: Int
    private enum CodingKeys: String, CodingKey { case column, row, width, height }
    init(column: Int, row: Int, width: Int, height: Int) { self.column = column; self.row = row; self.width = width; self.height = height }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, ["column", "row", "width", "height"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        column = try c.decode(Int.self, forKey: .column); row = try c.decode(Int.self, forKey: .row)
        width = try c.decode(Int.self, forKey: .width); height = try c.decode(Int.self, forKey: .height)
    }
    func overlaps(_ other: GridRect) -> Bool {
        column < other.column + other.width && other.column < column + width && row < other.row + other.height && other.row < row + height
    }
}
/// Shared Foundation-only grid projection and the two distinct rounding policies.
struct GridGeometryProfile: Equatable, Sendable {
    static let columns = 24, rows = 128
    static let padding = 16.0, gap = 14.0
    let pitchX: Double
    let pitchY = 36.0
    init(viewport: LayoutViewport) throws {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw BoardStorageError(.invalidData)
        }
        let resolved = max(52, (viewport.width - 2 * Self.padding + Self.gap) / Double(Self.columns))
        guard resolved.isFinite, (resolved * Double(Self.columns)).isFinite,
              (Self.padding + resolved * Double(Self.columns)).isFinite else { throw BoardStorageError(.invalidData) }
        pitchX = resolved
    }
    func frame(for rect: GridRect) -> CGRect {
        let x = Self.padding + Double(rect.column) * pitchX
        let y = Self.padding + Double(rect.row) * pitchY
        let width = Double(rect.width) * pitchX - Self.gap
        let height = Double(rect.height) * pitchY - Self.gap
        return CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
    func legacyQuantize(_ value: Double) throws -> Int {
        guard value.isFinite, let result = Int(exactly: ceil(value - 0.5)) else { throw BoardStorageError(.invalidData) }
        return result
    }
    func snapDelta(x: Double, y: Double) throws -> (column: Int, row: Int) {
        (column: try pointerCellDelta(x, pitch: pitchX), row: try pointerCellDelta(y, pitch: pitchY))
    }
    private func pointerCellDelta(_ delta: Double, pitch: Double) throws -> Int {
        guard delta.isFinite, pitch.isFinite, pitch > 0 else { throw BoardStorageError(.invalidData) }
        let units = delta / pitch
        guard units.isFinite, let result = Int(exactly: floor(units + 0.5)) else { throw BoardStorageError(.invalidData) }
        return result
    }
}
enum GridValidationError: Error, Equatable, Sendable { case hidden, bounds, minimum, collision, missing }
enum GridResolver {
    static let defaults: [GridItemID: GridRect] = [
        .calendar: .init(column: 0, row: 0, width: 18, height: 14), .wide: .init(column: 0, row: 14, width: 18, height: 7),
        .railTop: .init(column: 18, row: 0, width: 6, height: 7), .railMiddle: .init(column: 18, row: 7, width: 6, height: 7),
        .railBottom: .init(column: 18, row: 14, width: 6, height: 7)]
    static func validate(_ item: GridItemID, rect: GridRect, in layout: BoardLayout, allowHidden: Bool = false) throws {
        guard layout.placements[item] != nil else { throw GridValidationError.missing }
        guard allowHidden || !layout.hiddenSlots.contains(item.rawValue) else { throw GridValidationError.hidden }
        guard rect.width >= (item == .calendar ? 12 : 6), rect.height >= (item == .calendar ? 13 : 4) else { throw GridValidationError.minimum }
        guard rect.column >= 0, rect.row >= 0, rect.width <= GridGeometryProfile.columns, rect.height <= GridGeometryProfile.rows,
              rect.column <= GridGeometryProfile.columns - rect.width, rect.row <= GridGeometryProfile.rows - rect.height else { throw GridValidationError.bounds }
        for (other, occupied) in layout.placements where other != item && !layout.hiddenSlots.contains(other.rawValue) {
            guard occupied.width > 0, occupied.width <= GridGeometryProfile.columns, occupied.height > 0, occupied.height <= GridGeometryProfile.rows,
                  occupied.column >= 0, occupied.row >= 0, occupied.column <= GridGeometryProfile.columns - occupied.width,
                  occupied.row <= GridGeometryProfile.rows - occupied.height else { throw GridValidationError.bounds }
            if rect.overlaps(occupied) { throw GridValidationError.collision }
        }
    }
    static func place(_ item: GridItemID, rect: GridRect, in layout: BoardLayout) throws -> BoardLayout {
        try validate(item, rect: rect, in: layout)
        var result = layout; result.placements[item] = rect; return result
    }
    static func migrate(_ legacy: BoardLayout, viewport: LayoutViewport) throws -> BoardLayout {
        let profile = try PanelStepProfile(viewport: viewport)
        let geometry = try GridGeometryProfile(viewport: viewport)
        let pitchX = geometry.pitchX, pitchY = geometry.pitchY
        let padding = GridGeometryProfile.padding, gap = GridGeometryProfile.gap
        func frames(_ source: BoardLayout) throws -> [GridItemID: (Double, Double, Double, Double)] {
            let steps = try LayoutStepResolver.effectiveSteps(layout: source, profile: profile)
            let visible = profile.visibleRailSlots(hiddenSlots: source.hiddenSlots)
            let width = profile.contentWidth, height = profile.contentHeight
            let left = visible.isEmpty ? width : width - gap - profile.railWidth(steps.column)
            let wideVisible = !source.hiddenSlots.contains("wide")
            let calendarHeight = wideVisible ? height - gap - profile.height(.wide, step: steps.main) : height
            var result: [GridItemID: (Double, Double, Double, Double)] = [.calendar: (padding, padding, left, calendarHeight)]
            if wideVisible { result[.wide] = (padding, padding + calendarHeight + gap, left, profile.height(.wide, step: steps.main)) }
            let x = padding + left + gap
            var end = padding
            for slot in visible where slot != .railBottom {
                let y = end == padding ? padding : end + gap, h = profile.height(slot, step: steps[slot])
                result[GridItemID(rawValue: slot.rawValue)!] = (x, y, profile.railWidth(steps.column), h); end = y + h
            }
            if visible.contains(.railBottom) {
                let h = profile.height(.railBottom, step: steps.railBottom)
                result[.railBottom] = (x, padding + height - h, profile.railWidth(steps.column), h)
            }
            return result
        }
        let visible = try frames(legacy)
        var allVisible = legacy; allVisible.hiddenSlots = []
        let virtual = try frames(allVisible)
        var result = legacy; result.version = 4; result.placements = [:]
        var adjusted = false
        for item in GridItemID.allCases {
            guard let frame = (legacy.hiddenSlots.contains(item.rawValue) ? virtual[item] : visible[item]) else { throw BoardStorageError(.protectedData) }
            let values = [(frame.0 - padding) / pitchX, (frame.1 - padding) / pitchY, (frame.2 + gap) / pitchX, (frame.3 + gap) / pitchY]
            let raw: [Int]
            do { raw = try values.map { try geometry.legacyQuantize($0) } }
            catch { throw BoardStorageError(.protectedData) }
            let w = min(GridGeometryProfile.columns, max(item == .calendar ? 12 : 6, raw[2])), h = min(GridGeometryProfile.rows, max(item == .calendar ? 13 : 4, raw[3]))
            let c = min(GridGeometryProfile.columns - w, max(0, raw[0])), r = min(GridGeometryProfile.rows - h, max(0, raw[1]))
            var rect = GridRect(column: c, row: r, width: w, height: h)
            if values.enumerated().contains(where: { abs($0.element - Double(raw[$0.offset])) > 1e-7 }) || [c, r, w, h] != raw { adjusted = true }
            if !legacy.hiddenSlots.contains(item.rawValue) {
                var best: GridRect?, distance = Int.max
                for row in 0...(GridGeometryProfile.rows - h) { for column in 0...(GridGeometryProfile.columns - w) {
                    let candidate = GridRect(column: column, row: row, width: w, height: h)
                    let d = abs(column - c) + abs(row - r)
                    if d < distance && !result.placements.contains(where: { !legacy.hiddenSlots.contains($0.key.rawValue) && candidate.overlaps($0.value) }) {
                        best = candidate; distance = d
                    }
                } }
                guard let best else { throw BoardStorageError(.protectedData) }
                if best != rect { adjusted = true }; rect = best
            }
            result.placements[item] = rect
        }
        // Layout4 does not persist legacy steps; keep compatibility fields stable across restart.
        result.columnStep = 3; result.mainStep = 3; result.railTopStep = 3
        result.railMiddleStep = 3; result.railBottomStep = 3
        result.migrationNoticePending = adjusted
        try result.validate(); return result
    }
    static func restore(_ slot: SlotID, in layout: BoardLayout) throws -> BoardLayout {
        guard layout.hiddenSlots.contains(slot.rawValue) else { return layout }
        guard let item = GridItemID(rawValue: slot.rawValue), let original = layout.placements[item] else { throw GridValidationError.missing }
        guard original.width >= 6, original.width <= GridGeometryProfile.columns, original.height >= 4, original.height <= GridGeometryProfile.rows,
              original.column >= 0, original.row >= 0, original.column <= GridGeometryProfile.columns - original.width,
              original.row <= GridGeometryProfile.rows - original.height else { throw GridValidationError.bounds }
        var best: GridRect?, distance = Int.max
        for row in 0...(GridGeometryProfile.rows - original.height) { for column in 0...(GridGeometryProfile.columns - original.width) {
            let rect = GridRect(column: column, row: row, width: original.width, height: original.height)
            let d = abs(column - original.column) + abs(row - original.row)
            if d < distance, (try? validate(item, rect: rect, in: layout, allowHidden: true)) != nil { best = rect; distance = d }
        } }
        guard let best else { throw GridValidationError.collision }
        var result = layout; result.placements[item] = best; result.hiddenSlots.remove(slot.rawValue); return result
    }
}

struct BoardLayout: Codable, Equatable, Sendable {
    var version = 4
    var placements = GridResolver.defaults
    var migrationNoticePending = false
    var columnStep = 3, mainStep = 3, railTopStep = 3, railMiddleStep = 3, railBottomStep = 3
    // Source compatibility until the board/kit owners switch to the typed resolver.
    // These legacy read-only inputs are never encoded; validation rejects new ratio writes.
    var columnSplit: Double?
    var mainSplit: Double?
    var railSplit: Double?
    var railBottomSplit: Double?
    var slots: [String: PanelID] = ["wide": .projects, "railTop": .today, "railMiddle": .deadlines, "railBottom": .subscriptions]
    var hiddenSlots: Set<String> = []
    static let panelNames: Set<String> = ["today", "deadlines", "projects", "notes"]
    private static let legacySlots = ["projects":"wide", "today":"railTop", "deadlines":"railMiddle", "notes":"railBottom"]
    // Compatibility for the schema2 bridge until T-013 installs the slot projection.
    var hiddenPanels: Set<String> {
        get { Set(Self.legacySlots.compactMap { hiddenSlots.contains($0.value) ? $0.key : nil }) }
        set { hiddenSlots = Set(newValue.compactMap { Self.legacySlots[$0] }) }
    }
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, columnSplit, mainSplit, railSplit, railBottomSplit, hiddenPanels, slots, hiddenSlots
        case columnStep, mainStep, railTopStep, railMiddleStep, railBottomStep, placements, migrationNoticePending
    }
    var steps: LayoutSteps {
        LayoutSteps(column: PanelSizeStep(rawValue: columnStep) ?? .regular, main: PanelSizeStep(rawValue: mainStep) ?? .regular,
                    railTop: PanelSizeStep(rawValue: railTopStep) ?? .regular, railMiddle: PanelSizeStep(rawValue: railMiddleStep) ?? .regular,
                    railBottom: PanelSizeStep(rawValue: railBottomStep) ?? .regular)
    }
    mutating func setStep(_ split: LayoutSplit, _ step: PanelSizeStep) {
        switch split {
        case .column: columnStep = step.rawValue; case .main: mainStep = step.rawValue
        case .rail: railTopStep = step.rawValue; case .railBottom: railBottomStep = step.rawValue
        }
    }
    mutating func setHeightStep(_ slot: SlotID, _ step: PanelSizeStep) {
        switch slot {
        case .wide: mainStep = step.rawValue; case .railTop: railTopStep = step.rawValue
        case .railMiddle: railMiddleStep = step.rawValue; case .railBottom: railBottomStep = step.rawValue
        }
    }
    mutating func resetSizes() {
        columnStep = 3; mainStep = 3; railTopStep = 3; railMiddleStep = 3; railBottomStep = 3
        columnSplit = nil; mainSplit = nil; railSplit = nil; railBottomSplit = nil
        hiddenSlots = []
        if version == 4 { placements = GridResolver.defaults }
    }
    func validate() throws {
        guard (version == 3 || version == 4), [columnStep, mainStep, railTopStep, railMiddleStep, railBottomStep].allSatisfy({ (1...4).contains($0) }),
        [columnSplit, mainSplit, railSplit, railBottomSplit].allSatisfy({ $0 == nil }),
        Set(slots.keys) == Set(SlotID.allCases.map(\.rawValue)), Set(slots.values).count == 4,
        hiddenSlots.isSubset(of: Set(SlotID.allCases.map(\.rawValue))) else { throw BoardStorageError(.invalidData) }
        if version == 4 {
            guard Set(placements.keys) == Set(GridItemID.allCases) else { throw BoardStorageError(.invalidData) }
            for (item, rect) in placements {
                guard rect.width >= (item == .calendar ? 12 : 6), rect.height >= (item == .calendar ? 13 : 4),
                      rect.width <= GridGeometryProfile.columns, rect.height <= GridGeometryProfile.rows, rect.column >= 0, rect.row >= 0,
                      rect.column <= GridGeometryProfile.columns - rect.width, rect.row <= GridGeometryProfile.rows - rect.height else { throw BoardStorageError(.invalidData) }
            }
            for item in GridItemID.allCases {
                guard let rect = placements[item] else { throw BoardStorageError(.invalidData) }
                do {
                    if hiddenSlots.contains(item.rawValue) {
                        var isolated = self; isolated.hiddenSlots = Set(SlotID.allCases.map(\.rawValue)); isolated.placements = [item: rect]
                        try GridResolver.validate(item, rect: rect, in: isolated, allowHidden: true)
                    } else { try GridResolver.validate(item, rect: rect, in: self) }
                } catch { throw BoardStorageError(.invalidData) }
            }
        }
    }
    init(from decoder: Decoder) throws {
        self = try Self.decoded(from: decoder).layout
    }
    fileprivate static func decoded(from decoder: Decoder) throws -> (layout: Self, version: Int, repair: Bool) {
        var layout = Self()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try c.decode(Int.self, forKey: .version)
        guard (1...4).contains(sourceVersion) else { throw BoardStorageError(.protectedData) }
        layout.version = sourceVersion == 4 ? 4 : 3
        let sizes: [CodingKeys] = [.columnStep, .mainStep, .railTopStep, .railMiddleStep, .railBottomStep]
        let ratios: [CodingKeys] = [.columnSplit, .mainSplit, .railSplit, .railBottomSplit]
        let allowed: [CodingKeys] = [.version] + (sourceVersion == 4 ? [.placements, .migrationNoticePending] : sourceVersion == 3 ? sizes : ratios)
            + (sourceVersion == 1 ? [.hiddenPanels] : [.slots, .hiddenSlots])
        try requireKnownFields(decoder, allowed.map(\.rawValue))
        if sourceVersion == 1 {
            let panels = try c.decodeIfPresent([String].self, forKey: .hiddenPanels) ?? []
            layout.hiddenPanels = Set(panels).intersection(Self.panelNames)
        } else {
            layout.slots = try c.decode([String: PanelID].self, forKey: .slots)
            let hidden = try c.decode([String].self, forKey: .hiddenSlots)
            guard Set(hidden).count == hidden.count else { throw BoardStorageError(.invalidData) }
            layout.hiddenSlots = Set(hidden)
        }
        var repair = false
        if sourceVersion == 4 {
            let raw = try c.decode([String: GridRect].self, forKey: .placements)
            guard Set(raw.keys) == Set(GridItemID.allCases.map(\.rawValue)) else { throw BoardStorageError(.protectedData) }
            layout.placements = Dictionary(uniqueKeysWithValues: raw.map { (GridItemID(rawValue: $0.key)!, $0.value) })
            layout.migrationNoticePending = try c.decode(Bool.self, forKey: .migrationNoticePending)
        } else if sourceVersion == 3 {
            func step(_ key: CodingKeys) -> Int {
                guard let value = try? c.decode(Int.self, forKey: key), (1...4).contains(value) else { repair = true; return 3 }
                return value
            }
            layout.columnStep = step(.columnStep); layout.mainStep = step(.mainStep)
            layout.railTopStep = step(.railTopStep); layout.railMiddleStep = step(.railMiddleStep); layout.railBottomStep = step(.railBottomStep)
        } else {
            func ratio(_ key: CodingKeys) -> LegacyLayoutSplits.Scalar {
                if !c.contains(key) || (try? c.decodeNil(forKey: key)) == true { return .automatic }
                guard let value = try? c.decode(Double.self, forKey: key), value.isFinite, value > 0, value < 1 else {
                    repair = true; return .damaged
                }
                return .ratio(value)
            }
            let legacy = LegacyLayoutSplits(column: ratio(.columnSplit), main: ratio(.mainSplit),
                                             rail: ratio(.railSplit), railBottom: ratio(.railBottomSplit))
            if let viewport = decoder.userInfo[.layoutViewport] as? LayoutViewport {
                let steps = try legacy.nearest(profile: PanelStepProfile(viewport: viewport))
                layout.columnStep = steps.column.rawValue; layout.mainStep = steps.main.rawValue
                layout.railTopStep = steps.railTop.rawValue; layout.railMiddleStep = steps.railMiddle.rawValue; layout.railBottomStep = steps.railBottom.rawValue
            } else if legacy.hasRatio { throw BoardStorageError(.protectedData) }
        }
        try layout.validate()
        if sourceVersion < 4 {
            guard let viewport = decoder.userInfo[.layoutViewport] as? LayoutViewport else { throw BoardStorageError(.protectedData) }
            layout = try GridResolver.migrate(layout, viewport: viewport)
        }
        return (layout, sourceVersion, repair)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        if version == 4 {
            try c.encode(Dictionary(uniqueKeysWithValues: placements.map { ($0.key.rawValue, $0.value) }), forKey: .placements)
            try c.encode(migrationNoticePending, forKey: .migrationNoticePending)
            try c.encode(slots, forKey: .slots); try c.encode(hiddenSlots.sorted(), forKey: .hiddenSlots)
            return
        }
        try c.encode(columnStep, forKey: .columnStep); try c.encode(mainStep, forKey: .mainStep)
        try c.encode(railTopStep, forKey: .railTopStep); try c.encode(railMiddleStep, forKey: .railMiddleStep); try c.encode(railBottomStep, forKey: .railBottomStep)
        try c.encode(slots, forKey: .slots); try c.encode(hiddenSlots.sorted(), forKey: .hiddenSlots)
    }
}

/// Decode decisions belong to this load result, never to the persisted BoardState.
struct BoardDecodeResult: Decodable, Sendable {
    enum MigrationKind: Equatable, Sendable { case none, schema(Int), layout(Int) }
    let state: BoardState
    let migrationKind: MigrationKind
    let repairNeeded: Bool
    var requiresWrite: Bool { migrationKind != .none || repairNeeded }
    init(from decoder: Decoder) throws {
        var kind: MigrationKind = .none, repair = false
        state = try BoardState(from: decoder, migrationKind: &kind, repairNeeded: &repair)
        migrationKind = kind; repairNeeded = repair
    }
    static func decode(_ data: Data, viewport: LayoutViewport? = nil, defaultWeatherCityID: String? = nil) throws -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[.layoutViewport] = viewport
        decoder.userInfo[.boardDefaultWeatherCityID] = defaultWeatherCityID
        return try decoder.decode(Self.self, from: data)
    }
}

struct BoardState: Codable, Equatable, Sendable {
    var version = 3
    var boardRevision = 0
    var notes = ""
    var milestones: [Milestone] = []
    var projects: [Project] = []
    var pinnedEventKeys: Set<String> = []
    var hiddenCalendarIDs: Set<String> = []
    var settings = BoardSettings()
    var eventProjectLinks: [String: String] = [:]
    var layout = BoardLayout()
    var subscriptions: [Subscription] = []
    var todos: [Todo] = []
    var habits: [Habit] = []
    var worldClockCities: [WorldClockCity] = []
    var focusTimer = FocusTimerState()
    var focusSessions: [FocusSession] = []
    var notificationAttempts: [NotificationAttempt] = []
    var networkBudgetInitialized = false
    init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, boardRevision, notes, milestones, projects, pinnedEventKeys, hiddenCalendarIDs, settings, eventProjectLinks, layout
        case subscriptions, todos, habits, worldClockCities, focusTimer, focusSessions, notificationAttempts, networkBudgetInitialized
    }
    init(from decoder: Decoder) throws {
        var kind: BoardDecodeResult.MigrationKind = .none, repair = false
        try self.init(from: decoder, migrationKind: &kind, repairNeeded: &repair)
    }
    fileprivate init(from decoder: Decoder, migrationKind: inout BoardDecodeResult.MigrationKind, repairNeeded: inout Bool) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = c.contains(.version) ? try c.decode(Int.self, forKey: .version) : 1
        guard (1...3).contains(sourceVersion) else { throw BoardStorageError(.unsupportedVersion) }
        if sourceVersion < 3 { migrationKind = .schema(sourceVersion) }
        self.init()
        boardRevision = sourceVersion == 1 || !c.contains(.boardRevision) ? 0 : try c.decode(Int.self, forKey: .boardRevision)
        if sourceVersion < 3 {
            guard boardRevision >= 0, boardRevision < Int.max else { throw BoardStorageError(.protectedData) }
            boardRevision += 1
        }
        if sourceVersion < 3 {
            let added: [CodingKeys] = [.subscriptions, .todos, .habits, .worldClockCities, .focusTimer, .focusSessions, .notificationAttempts, .networkBudgetInitialized]
            guard !added.contains(where: c.contains) else { throw BoardStorageError(.protectedData) }
        }
        notes = c.contains(.notes) ? try c.decode(String.self, forKey: .notes) : ""
        if sourceVersion == 1 {
            projects = c.contains(.projects) ? try c.decode([LegacyProject].self, forKey: .projects).map(\.value) : []
            milestones = c.contains(.milestones) ? try c.decode([LegacyMilestone].self, forKey: .milestones).map(\.value) : []
        } else {
            projects = c.contains(.projects) ? try c.decode([Project].self, forKey: .projects) : []
            milestones = c.contains(.milestones) ? try c.decode([Milestone].self, forKey: .milestones) : []
        }
        pinnedEventKeys = c.contains(.pinnedEventKeys) ? try c.decode(Set<String>.self, forKey: .pinnedEventKeys) : []
        hiddenCalendarIDs = c.contains(.hiddenCalendarIDs) ? try c.decode(Set<String>.self, forKey: .hiddenCalendarIDs) : []
        settings = c.contains(.settings) ? try c.decode(BoardSettings.self, forKey: .settings) : BoardSettings()
        if !c.contains(.settings) { settings.weather.cityID = decoder.userInfo[.boardDefaultWeatherCityID] as? String }
        eventProjectLinks = c.contains(.eventProjectLinks) ? try c.decode([String: String].self, forKey: .eventProjectLinks) : [:]
        let projectIDs = Set(projects.map(\.id))
        eventProjectLinks = eventProjectLinks.mapValues { reference in
            guard let id = UUID(uuidString: reference), projectIDs.contains(id) else { return reference }
            return id.uuidString.lowercased()
        }
        if sourceVersion == 3, !c.contains(.layout) { throw BoardStorageError(.protectedData) }
        if c.contains(.layout) {
            let decoded = try BoardLayout.decoded(from: c.superDecoder(forKey: .layout))
            guard sourceVersion < 3 || decoded.version >= 2 else { throw BoardStorageError(.protectedData) }
            layout = decoded.layout
            repairNeeded = decoded.repair
            if sourceVersion == 3, decoded.version < 4 || decoded.repair {
                guard boardRevision >= 0, boardRevision < Int.max else { throw BoardStorageError(.protectedData) }
                boardRevision += 1
                if decoded.version < 4 { migrationKind = .layout(decoded.version) }
            }
        }
        if !c.contains(.layout) && sourceVersion < 3 {
            guard let viewport = decoder.userInfo[.layoutViewport] as? LayoutViewport else { throw BoardStorageError(.protectedData) }
            var legacy = BoardLayout(); legacy.version = 3
            layout = try GridResolver.migrate(legacy, viewport: viewport)
        }
        if sourceVersion == 3 {
            subscriptions = c.contains(.subscriptions) ? try c.decode([Subscription].self, forKey: .subscriptions) : []
            todos = c.contains(.todos) ? try c.decode([Todo].self, forKey: .todos) : []
            habits = c.contains(.habits) ? try c.decode([Habit].self, forKey: .habits) : []
            worldClockCities = c.contains(.worldClockCities) ? try c.decode([WorldClockCity].self, forKey: .worldClockCities) : []
            focusTimer = c.contains(.focusTimer) ? try c.decode(FocusTimerState.self, forKey: .focusTimer) : FocusTimerState()
            focusSessions = c.contains(.focusSessions) ? try c.decode([FocusSession].self, forKey: .focusSessions) : []
            notificationAttempts = c.contains(.notificationAttempts) ? try c.decode([NotificationAttempt].self, forKey: .notificationAttempts) : []
            networkBudgetInitialized = c.contains(.networkBudgetInitialized) ? try c.decode(Bool.self, forKey: .networkBudgetInitialized) : false
        }
        try validate()
    }
    func validate() throws {
        guard version == 3, boardRevision >= 0,
              Set(projects.map(\.id)).count == projects.count,
              Set(milestones.map(\.id)).count == milestones.count,
              projects.allSatisfy({ (0...100).contains($0.progress) && $0.colorHex.utf8.count == 6 && validColor($0.colorHex, fallback: "") == $0.colorHex.uppercased() }),
              (projects.map(\.title) + milestones.map(\.title)).allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500
              }), milestones.allSatisfy({ $0.colorHex.utf8.count == 6 && validColor($0.colorHex, fallback: "") == $0.colorHex.uppercased() }),
              settings.fontScale.isFinite, (0.9...1.5).contains(settings.fontScale),
              settings.opacity.isFinite, (0.75...1).contains(settings.opacity) else { throw BoardStorageError(.invalidData) }
        try layout.validate()
        try validatePanelRecords()
    }
}

struct BoardStorageError: LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable {
        case protectedData = "STORAGE_PROTECTED", writeFailed = "STORAGE_WRITE_FAILED"
        case invalidData = "VALIDATION_FAILED", unsupportedVersion = "UNSUPPORTED_SCHEMA", conflict = "BOARD_CONFLICT"
    }
    let code: Code
    let committed: Bool
    let committedState: BoardState?
    init(_ code: Code, committed: Bool = false, committedState: BoardState? = nil) {
        self.code = code; self.committed = committed; self.committedState = committedState
    }
    var errorDescription: String? {
        switch code {
        case .protectedData, .unsupportedVersion: "Your saved data is protected. The original file has been preserved."
        case .invalidData: "The board contains invalid data. Your saved data has been preserved."
        case .writeFailed: "Could not save the board. Please check disk space and try again."
        case .conflict: "The board has changed. Please refresh and try again."
        }
    }
}

protocol BoardPersistence {
    func load() throws -> BoardState
    func save(_ state: BoardState) throws
}

/// Serial, authoritative in-memory base; never publish a candidate before the persistence result.
@MainActor
final class BoardStore {
    private(set) var state = BoardState()
    private(set) var canSave = true
    private(set) var lastError: BoardStorageError?
    private let persistence: (any BoardPersistence)?
    /// Native composition hooks cover every service write, including committed failures.
    var didPublish: ((BoardState, BoardState) -> Void)?
    var interceptCommit: ((_ committed: Bool) throws -> Void)?
    init(persistence: (any BoardPersistence)? = nil, initialState: BoardState = BoardState()) {
        self.persistence = persistence
        do { state = try persistence?.load() ?? initialState }
        catch {
            canSave = false
            let failure = (error as? BoardStorageError) ?? BoardStorageError(.protectedData)
            if failure.committed, let committed = failure.committedState { state = committed }
            lastError = failure
        }
    }
    @discardableResult func retryLoad() throws -> BoardState {
        let previous = state
        defer { if state != previous { didPublish?(previous, state) } }
        do {
            state = try persistence?.load() ?? state
            canSave = true; lastError = nil
            return state
        } catch {
            let failure = (error as? BoardStorageError) ?? BoardStorageError(.protectedData)
            if failure.committed, let committed = failure.committedState { state = committed }
            canSave = false; lastError = failure
            throw failure
        }
    }
    @discardableResult func commit(_ candidate: BoardState, baseRevision: Int? = nil) throws -> BoardState {
        let previous = state
        defer { if state != previous { didPublish?(previous, state) } }
        do {
            guard canSave else { throw BoardStorageError(.protectedData) }
            guard baseRevision == nil || baseRevision == state.boardRevision else { throw BoardStorageError(.conflict) }
            guard candidate.layout.version == 4 else { throw BoardStorageError(.invalidData) }
            try candidate.validate()
        } catch {
            let failure = (error as? BoardStorageError) ?? BoardStorageError(.invalidData)
            lastError = failure
            throw failure
        }
        guard candidate != state else { lastError = nil; return state }
        guard state.boardRevision < Int.max else {
            let failure = BoardStorageError(.protectedData)
            lastError = failure
            throw failure
        }
        var next = candidate
        next.boardRevision = state.boardRevision + 1
        do { try interceptCommit?(false) }
        catch { lastError = BoardStorageError(.writeFailed); throw error }
        do { try persistence?.save(next) }
        catch {
            let failure = (error as? BoardStorageError) ?? BoardStorageError(.writeFailed)
            if failure.committed { state = next }
            lastError = failure
            throw failure
        }
        state = next; lastError = nil
        do { try interceptCommit?(true) }
        catch { lastError = BoardStorageError(.writeFailed, committed: true); throw error }
        return next
    }
}

struct LocalStateFile: BoardPersistence {
    let url: URL
    /// T-014/T-013 inject the catalog's safe mapping; nil represents an unmapped Mac zone.
    var defaultWeatherCityID: String? = nil
    /// Actual BoardRoot logical bounds; a missing viewport defers every legacy migration.
    var layoutViewport: LayoutViewport? = nil
    /// Filesystem transaction boundaries, injectable without changing the real writer.
    enum Phase: String, CaseIterable { case candidateValidated, backupWritten, backupVerified, stagingWritten, stagingVerified, beforeReplace, replaced, verified }
    var fault: ((Phase) throws -> Void)? = nil
    private static let maximumBytes = 8 * 1_048_576
    private struct Version: Decodable { let version: Int? }

    func load() throws -> BoardState {
        guard try checkPath() else {
            var state = BoardState(); state.settings.weather.cityID = defaultWeatherCityID
            return state
        }
        let original = try readFile(url)
        let decoded = try decodeResult(original)
        let state = decoded.state
        if decoded.requiresWrite {
            if decoded.migrationKind != .none, layoutViewport == nil { throw BoardStorageError(.protectedData) }
            do {
                try withDirectory { directory in
                    let source = try fingerprint()
                    try fault?(.candidateValidated)
                    try backup(original, prefix: backupPrefix(decoded), directory: directory)
                    guard try fingerprint() == source, try readFile(url) == original else { throw BoardStorageError(.conflict) }
                    try publish(try encode(state), directory: directory, expectedOriginal: original, expectedFingerprint: source)
                }
            } catch let failure as BoardStorageError where failure.committed {
                throw BoardStorageError(failure.code, committed: true, committedState: state)
            }
        }
        return state
    }

    func save(_ state: BoardState) throws {
        guard state.layout.version == 4 else { throw BoardStorageError(.invalidData) }
        try state.validate()
        let original = try checkPath() ? readFile(url) : nil
        let decoded = try original.map { try decodeResult($0) }
        if let decoded, decoded.requiresWrite, layoutViewport == nil { throw BoardStorageError(.protectedData) }
        let data = try encode(state)
        try withDirectory { directory in
            let source = original == nil ? nil : try fingerprint()
            if let original {
                if let decoded, decoded.requiresWrite { try backup(original, prefix: backupPrefix(decoded), directory: directory) }
                guard try readFile(url) == original else { throw BoardStorageError(.conflict) }
            }
            try publish(data, directory: directory, expectedOriginal: original, expectedFingerprint: source)
        }
    }

    private func decode(_ data: Data) throws -> BoardState {
        try decodeResult(data).state
    }
    private func decodeResult(_ data: Data) throws -> BoardDecodeResult {
        guard data.count <= Self.maximumBytes else { throw BoardStorageError(.protectedData) }
        do {
            let version = try JSONDecoder().decode(Version.self, from:data).version ?? 1
            return try BoardDecodeResult.decode(data, viewport: layoutViewport, defaultWeatherCityID: version < 3 ? defaultWeatherCityID : nil)
        }
        catch let error as BoardStorageError { throw error }
        catch { throw BoardStorageError(.protectedData) }
    }
    private func encode(_ state: BoardState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumBytes else { throw BoardStorageError(.invalidData) }
        return data
    }
    /// Inspect every existing component, including dangling symlinks, without following it.
    private func checkPath() throws -> Bool {
        // Foundation may shorten an existing /private/var path to symlinked /var.
        // Inspect the supplied absolute path so normalization cannot introduce a link.
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.pathComponents.contains("."), !url.pathComponents.contains("..") else { throw BoardStorageError(.protectedData) }
        var path = url
        var exists = false
        while path.path != "/" {
            var info = stat()
            if lstat(path.path, &info) == 0 {
                let kind = info.st_mode & S_IFMT
                guard kind != S_IFLNK, kind == (path == url ? S_IFREG : S_IFDIR) else {
                    throw BoardStorageError(.protectedData)
                }
                if path == url { exists = true }
            } else if errno != ENOENT { throw BoardStorageError(.protectedData) }
            path.deleteLastPathComponent()
        }
        return exists
    }
    private func readFile(_ location: URL) throws -> Data {
        let fd = open(location.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw BoardStorageError(.protectedData) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Self.maximumBytes else { throw BoardStorageError(.protectedData) }
        do { return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data() }
        catch { throw BoardStorageError(.protectedData) }
    }
    private func withDirectory<T>(_ action: (Int32) throws -> T) throws -> T {
        _ = try checkPath()
        let parent = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw BoardStorageError(.writeFailed) }
        _ = try checkPath()
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw BoardStorageError(.writeFailed) }
        defer { close(directory) }
        guard fchmod(directory, 0o700) == 0 else { throw BoardStorageError(.writeFailed) }
        return try action(directory)
    }
    private func writePrivate(_ data: Data, name: String, directory: Int32) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BoardStorageError(.writeFailed) }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw BoardStorageError(.writeFailed) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BoardStorageError(.writeFailed) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw BoardStorageError(.writeFailed) }
    }
    private struct Fingerprint: Equatable {
        let inode: UInt64
        let mode: UInt16
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }
    private func fingerprint() throws -> Fingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw BoardStorageError(.protectedData) }
        return Fingerprint(inode: info.st_ino, mode: info.st_mode, size: info.st_size,
                           seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
    private func backupPrefix(_ decoded: BoardDecodeResult) -> String {
        switch decoded.migrationKind {
        case .schema(let version): "board.v\(version).backup"
        case .layout(let version): "board.v3.layout\(version).backup"
        case .none: "board.v3.layout3.backup"
        }
    }
    private func backup(_ data: Data, prefix: String, directory: Int32) throws {
        let parent = url.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0 == prefix + ".json" || ($0.hasPrefix(prefix + "-") && $0.hasSuffix(".json")) }.sorted()
        let hash = SHA256.hash(data: data)
        for name in names {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { throw BoardStorageError(.protectedData) }
            let existing = try readFile(parent.appendingPathComponent(name))
            if info.st_mode & 0o777 == 0o600, existing == data, SHA256.hash(data: existing) == hash {
                try fault?(.backupVerified)
                return
            }
        }
        let name = names.isEmpty ? prefix + ".json" : prefix + "-" + UUID().uuidString.lowercased() + ".json"
        try writePrivate(data, name: name, directory: directory)
        try fault?(.backupWritten)
        var info = stat()
        let copy = try readFile(parent.appendingPathComponent(name))
        guard copy == data, SHA256.hash(data: copy) == hash,
              fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & 0o777 == 0o600, fsync(directory) == 0 else { throw BoardStorageError(.writeFailed) }
        try fault?(.backupVerified)
    }
    private func publish(_ data: Data, directory: Int32, expectedOriginal: Data?, expectedFingerprint: Fingerprint?) throws {
        let temporary = ".board-" + UUID().uuidString.lowercased() + ".tmp"
        defer { unlinkat(directory, temporary, 0) }
        try writePrivate(data, name: temporary, directory: directory)
        try fault?(.stagingWritten)
        let staging = url.deletingLastPathComponent().appendingPathComponent(temporary)
        let staged = try readFile(staging)
        guard SHA256.hash(data: staged) == SHA256.hash(data: data), try decode(staged) == decode(data) else { throw BoardStorageError(.writeFailed) }
        var stagingInfo = stat()
        guard fstatat(directory, temporary, &stagingInfo, AT_SYMLINK_NOFOLLOW) == 0, stagingInfo.st_mode & 0o777 == 0o600 else { throw BoardStorageError(.writeFailed) }
        try fault?(.stagingVerified)
        try fault?(.beforeReplace)
        if let expectedOriginal {
            guard try readFile(url) == expectedOriginal, try fingerprint() == expectedFingerprint else { throw BoardStorageError(.conflict) }
        }
        var info = stat()
        if fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard expectedOriginal != nil else { throw BoardStorageError(.conflict) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw BoardStorageError(.protectedData) }
            guard renameat(directory, temporary, directory, url.lastPathComponent) == 0 else { throw BoardStorageError(.writeFailed) }
        } else {
            guard errno == ENOENT, linkat(directory, temporary, directory, url.lastPathComponent, 0) == 0 else {
                throw BoardStorageError(.writeFailed)
            }
        }
        // From here onward the new bytes exist, even if durability/permission checks fail.
        do {
            try fault?(.replaced)
            guard fsync(directory) == 0,
              fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else {
                throw BoardStorageError(.writeFailed, committed: true)
            }
            guard try readFile(url) == data else { throw BoardStorageError(.writeFailed, committed: true) }
            try fault?(.verified)
        } catch { throw BoardStorageError(.writeFailed, committed: true) }
    }
}

// Typed schema3 records live here so the established Core-only test target remains valid.
struct Instant: Codable, Hashable, Comparable, Sendable {
    let value: String
    var date: Date { Self.formatter().date(from: value)! }
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }
    init(_ value: String) throws {
        guard value.utf8.count == 24, value.hasSuffix("Z"), let date = Self.formatter().date(from: value),
              Self.formatter().string(from: date) == value else { throw BoardStorageError(.invalidData) }
        self.value = value
    }
    init(date: Date) { value = Self.formatter().string(from: date) }
    static func < (a: Self, b: Self) -> Bool { a.value < b.value }
    init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
}

enum SubscriptionCycle: String, Codable, CaseIterable, Sendable { case weekly, monthly, yearly }
enum FocusStatus: String, Codable, Sendable { case idle, running, paused, completed }
enum FocusMode: String, Codable, Sendable { case focus, `break` }
enum FocusCompletionKind: String, Codable, Sendable { case finished, stopped }
enum NotificationKind: String, Codable, Sendable { case subscription, focus }
enum NotificationAttemptState: String, Codable, Sendable { case attempted, submitted, failed }

struct WeatherSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var cityID: String? = nil
}
extension WeatherSettings {
    enum CodingKeys: String, CodingKey, CaseIterable { case enabled, cityID }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        cityID = try c.decodeIfPresent(String.self, forKey: .cityID)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(cityID, forKey: .cityID)
    }
}

struct FocusSettings: Codable, Equatable, Sendable {
    var focusSeconds: Int = 1500
    var breakSeconds: Int = 300
    var notifyOnFinish: Bool = false
}
extension FocusSettings {
    enum CodingKeys: String, CodingKey, CaseIterable { case focusSeconds, breakSeconds, notifyOnFinish }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusSeconds = (try? c.decode(Int.self, forKey: .focusSeconds)) ?? 1500
        breakSeconds = (try? c.decode(Int.self, forKey: .breakSeconds)) ?? 300
        notifyOnFinish = (try? c.decode(Bool.self, forKey: .notifyOnFinish)) ?? false
        if !(60...14400).contains(focusSeconds) { focusSeconds = 1500 }
        if !(60...3600).contains(breakSeconds) { breakSeconds = 300 }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(focusSeconds, forKey: .focusSeconds)
        try c.encode(breakSeconds, forKey: .breakSeconds)
        try c.encode(notifyOnFinish, forKey: .notifyOnFinish)
    }
}

struct Subscription: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var nextDate: DateOnly
    var cycle: SubscriptionCycle
    var amount: String
    var currency: String
    var paymentMemo: String = ""
    var notify: Bool = false
    var anchorDate: DateOnly
    var scheduleID: UUID
}
extension Subscription {
    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, nextDate, cycle, amount, currency, paymentMemo, notify, anchorDate, scheduleID }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        nextDate = try c.decode(DateOnly.self, forKey: .nextDate)
        cycle = try c.decode(SubscriptionCycle.self, forKey: .cycle)
        amount = try c.decode(String.self, forKey: .amount)
        currency = try c.decode(String.self, forKey: .currency)
        paymentMemo = try c.decode(String.self, forKey: .paymentMemo)
        notify = try c.decode(Bool.self, forKey: .notify)
        anchorDate = try c.decode(DateOnly.self, forKey: .anchorDate)
        scheduleID = try c.decode(UUID.self, forKey: .scheduleID)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(nextDate, forKey: .nextDate)
        try c.encode(cycle, forKey: .cycle)
        try c.encode(amount, forKey: .amount)
        try c.encode(currency, forKey: .currency)
        try c.encode(paymentMemo, forKey: .paymentMemo)
        try c.encode(notify, forKey: .notify)
        try c.encode(anchorDate, forKey: .anchorDate)
        try c.encode(scheduleID.uuidString.lowercased(), forKey: .scheduleID)
    }
}

struct Todo: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var completed: Bool = false
    var createdAt: Instant
    var completedAt: Instant? = nil
}
extension Todo {
    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, completed, createdAt, completedAt }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        completed = try c.decode(Bool.self, forKey: .completed)
        createdAt = try c.decode(Instant.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(Instant.self, forKey: .completedAt)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(completed, forKey: .completed)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(completedAt, forKey: .completedAt)
    }
}

struct Habit: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdOn: DateOnly
    var marks: [DateOnly] = []
}
extension Habit {
    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, createdOn, marks }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdOn = try c.decode(DateOnly.self, forKey: .createdOn)
        marks = try c.decode([DateOnly].self, forKey: .marks)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdOn, forKey: .createdOn)
        try c.encode(marks, forKey: .marks)
    }
}

struct WorldClockCity: Identifiable, Codable, Equatable, Sendable {
    var id: String
}
extension WorldClockCity {
    enum CodingKeys: String, CodingKey, CaseIterable { case id }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
    }
}

struct FocusActiveSegment: Codable, Equatable, Sendable {
    var startAt: Instant
    var timeZone: String
}
extension FocusActiveSegment {
    enum CodingKeys: String, CodingKey, CaseIterable { case startAt, timeZone }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startAt = try c.decode(Instant.self, forKey: .startAt)
        timeZone = try c.decode(String.self, forKey: .timeZone)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startAt, forKey: .startAt)
        try c.encode(timeZone, forKey: .timeZone)
    }
}

struct FocusInterval: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var from: Instant
    var to: Instant
    var day: DateOnly
    var timeZone: String
    var projectID: UUID? = nil
    var durationMilliseconds: Int
}
extension FocusInterval {
    enum CodingKeys: String, CodingKey, CaseIterable { case id, from, to, day, timeZone, projectID, durationMilliseconds }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        from = try c.decode(Instant.self, forKey: .from)
        to = try c.decode(Instant.self, forKey: .to)
        day = try c.decode(DateOnly.self, forKey: .day)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        durationMilliseconds = try c.decode(Int.self, forKey: .durationMilliseconds)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(day, forKey: .day)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(projectID?.uuidString.lowercased(), forKey: .projectID)
        try c.encode(durationMilliseconds, forKey: .durationMilliseconds)
    }
}

struct FocusSession: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var mode: FocusMode
    var projectIDAtStart: UUID? = nil
    var currentProjectID: UUID? = nil
    var plannedSeconds: Int
    var startedAt: Instant
    var endAt: Instant? = nil
    var remainingSeconds: Int? = nil
    var activeSegment: FocusActiveSegment? = nil
    var intervals: [FocusInterval] = []
    var completedAt: Instant? = nil
    var completionKind: FocusCompletionKind? = nil
}
extension FocusSession {
    enum CodingKeys: String, CodingKey, CaseIterable { case id, mode, projectIDAtStart, currentProjectID, plannedSeconds, startedAt, endAt, remainingSeconds, activeSegment, intervals, completedAt, completionKind }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mode = try c.decode(FocusMode.self, forKey: .mode)
        projectIDAtStart = try c.decodeIfPresent(UUID.self, forKey: .projectIDAtStart)
        currentProjectID = try c.decodeIfPresent(UUID.self, forKey: .currentProjectID)
        plannedSeconds = try c.decode(Int.self, forKey: .plannedSeconds)
        startedAt = try c.decode(Instant.self, forKey: .startedAt)
        endAt = try c.decodeIfPresent(Instant.self, forKey: .endAt)
        remainingSeconds = try c.decodeIfPresent(Int.self, forKey: .remainingSeconds)
        activeSegment = try c.decodeIfPresent(FocusActiveSegment.self, forKey: .activeSegment)
        intervals = try c.decode([FocusInterval].self, forKey: .intervals)
        completedAt = try c.decodeIfPresent(Instant.self, forKey: .completedAt)
        completionKind = try c.decodeIfPresent(FocusCompletionKind.self, forKey: .completionKind)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(mode, forKey: .mode)
        try c.encode(projectIDAtStart?.uuidString.lowercased(), forKey: .projectIDAtStart)
        try c.encode(currentProjectID?.uuidString.lowercased(), forKey: .currentProjectID)
        try c.encode(plannedSeconds, forKey: .plannedSeconds)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endAt, forKey: .endAt)
        try c.encode(remainingSeconds, forKey: .remainingSeconds)
        try c.encode(activeSegment, forKey: .activeSegment)
        try c.encode(intervals, forKey: .intervals)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(completionKind, forKey: .completionKind)
    }
}

struct FocusTimerState: Codable, Equatable, Sendable {
    var status: FocusStatus = .idle
    var mode: FocusMode = .focus
    var projectID: UUID? = nil
    var session: FocusSession? = nil
}
extension FocusTimerState {
    enum CodingKeys: String, CodingKey, CaseIterable { case status, mode, projectID, session }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(FocusStatus.self, forKey: .status)
        mode = try c.decode(FocusMode.self, forKey: .mode)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        session = try c.decodeIfPresent(FocusSession.self, forKey: .session)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(mode, forKey: .mode)
        try c.encode(projectID?.uuidString.lowercased(), forKey: .projectID)
        try c.encode(session, forKey: .session)
    }
}

struct NotificationAttempt: Codable, Equatable, Sendable {
    var key: String
    var kind: NotificationKind
    var subscriptionID: UUID? = nil
    var scheduleID: UUID? = nil
    var dueDate: DateOnly? = nil
    var sessionID: UUID? = nil
    var attemptedAt: Instant
    var state: NotificationAttemptState = .attempted
}
extension NotificationAttempt {
    enum CodingKeys: String, CodingKey, CaseIterable { case key, kind, subscriptionID, scheduleID, dueDate, sessionID, attemptedAt, state }
    init(from decoder: Decoder) throws {
        try requireKnownFields(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decode(NotificationKind.self, forKey: .kind)
        subscriptionID = try c.decodeIfPresent(UUID.self, forKey: .subscriptionID)
        scheduleID = try c.decodeIfPresent(UUID.self, forKey: .scheduleID)
        dueDate = try c.decodeIfPresent(DateOnly.self, forKey: .dueDate)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        attemptedAt = try c.decode(Instant.self, forKey: .attemptedAt)
        state = try c.decode(NotificationAttemptState.self, forKey: .state)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(kind, forKey: .kind)
        try c.encode(subscriptionID?.uuidString.lowercased(), forKey: .subscriptionID)
        try c.encode(scheduleID?.uuidString.lowercased(), forKey: .scheduleID)
        try c.encode(dueDate, forKey: .dueDate)
        try c.encode(sessionID?.uuidString.lowercased(), forKey: .sessionID)
        try c.encode(attemptedAt, forKey: .attemptedAt)
        try c.encode(state, forKey: .state)
    }
}

/// Decimal parsing never passes through Double. Arithmetic must check NSDecimal's status.
enum ExactDecimal {
    static let locale = Locale(identifier: "en_US_POSIX")
    static let limit = Decimal(string: "10000000000000000000000000000000000000", locale: locale)!
    static func scaled(_ value: String, integerDigits: Int, scale: Int) throws -> Decimal {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty, whole.count <= integerDigits,
              whole.utf8.allSatisfy({ (48...57).contains($0) }), whole.count == 1 || whole.first != "0",
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= scale && parts[1].utf8.allSatisfy({ (48...57).contains($0) })) else {
            throw BoardStorageError(.invalidData)
        }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard let result = Decimal(string: String(whole) + fraction + String(repeating: "0", count: scale - fraction.count), locale: locale),
              result >= 0, result < limit else { throw BoardStorageError(.invalidData) }
        return result
    }
    static func add(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var a = lhs, b = rhs, result = Decimal()
        guard NSDecimalAdd(&result, &a, &b, .plain) == .noError, !result.isNaN, result >= 0, result < limit else { throw BoardStorageError(.invalidData) }
        return result
    }
    static func multiply(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var a = lhs, b = rhs, result = Decimal()
        guard NSDecimalMultiply(&result, &a, &b, .plain) == .noError, !result.isNaN, result >= 0, result < limit else { throw BoardStorageError(.invalidData) }
        return result
    }
}

extension BoardState {
    func validatePanelRecords() throws {
        func require(_ condition: Bool) throws { guard condition else { throw BoardStorageError(.invalidData) } }
        func title(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 500 }
        try require((60...14400).contains(settings.focus.focusSeconds) && (60...3600).contains(settings.focus.breakSeconds))
        try require(Set(subscriptions.map(\.id)).count == subscriptions.count && Set(todos.map(\.id)).count == todos.count && Set(habits.map(\.id)).count == habits.count)
        // Supported currencies/units are shared with PanelMath and exposed by native metadata.
        var currencyNumerators: [String: Decimal] = [:]
        for value in subscriptions {
            try require(title(value.name) && value.paymentMemo.count <= 4096 && PanelCurrency.minorUnits[value.currency] != nil)
            let amount = try ExactDecimal.scaled(value.amount, integerDigits: 12, scale: 4)
            let factor = Decimal(value.cycle == .weekly ? 52 : value.cycle == .monthly ? 12 : 1)
            currencyNumerators[value.currency] = try ExactDecimal.add(currencyNumerators[value.currency] ?? 0, ExactDecimal.multiply(amount, factor))
            try require(value.nextDate >= value.anchorDate)
        }
        for value in todos { try require(title(value.title) && value.completed == (value.completedAt != nil)) }
        for value in habits { try require(title(value.title) && value.marks == Array(Set(value.marks)).sorted()) }
        try require(worldClockCities.count <= 4 && Set(worldClockCities.map(\.id)).count == worldClockCities.count && worldClockCities.allSatisfy { !$0.id.isEmpty && $0.id.count <= 100 })
        try require(Set(focusSessions.map(\.id)).count == focusSessions.count)
        var sessions: [UUID: FocusSession] = [:]
        var intervalIDs = Set<UUID>()
        for session in focusSessions + (focusTimer.session.map { [$0] } ?? []) {
            if let existing = sessions[session.id] {
                try require(existing == session)
                continue
            }
            sessions[session.id] = session
            try require((60...(session.mode == .focus ? 14400 : 3600)).contains(session.plannedSeconds) && (session.remainingSeconds == nil || (0...session.plannedSeconds).contains(session.remainingSeconds!)))
            try require((session.completedAt == nil) == (session.completionKind == nil))
            try require(session.activeSegment == nil || TimeZone(identifier: session.activeSegment!.timeZone) != nil)
            var total = 0
            for interval in session.intervals {
                let sum = total.addingReportingOverflow(interval.durationMilliseconds)
                try require(!sum.overflow && interval.durationMilliseconds >= 0 && interval.to >= interval.from && TimeZone(identifier: interval.timeZone) != nil)
                total = sum.partialValue
                try require(intervalIDs.insert(interval.id).inserted)
            }
            try require(total <= session.plannedSeconds * 1000 && Set(session.intervals.map(\.id)).count == session.intervals.count)
        }
        switch focusTimer.status {
        case .idle: try require(focusTimer.session == nil)
        case .running: try require(focusTimer.session?.endAt != nil && focusTimer.session?.activeSegment != nil && focusTimer.session?.completedAt == nil)
        case .paused: try require(focusTimer.session != nil && focusTimer.session?.endAt == nil && focusTimer.session?.activeSegment == nil && focusTimer.session?.remainingSeconds != nil)
        case .completed: try require(focusTimer.session?.completedAt != nil)
        }
        try require(Set(notificationAttempts.map(\.key)).count == notificationAttempts.count)
        for attempt in notificationAttempts {
            switch attempt.kind {
            case .subscription:
                guard let id = attempt.subscriptionID, let schedule = attempt.scheduleID, let due = attempt.dueDate else { throw BoardStorageError(.invalidData) }
                try require(attempt.sessionID == nil && attempt.key == "\(id.uuidString.lowercased())/\(schedule.uuidString.lowercased())/\(due)")
            case .focus:
                guard let id = attempt.sessionID else { throw BoardStorageError(.invalidData) }
                try require(attempt.subscriptionID == nil && attempt.scheduleID == nil && attempt.dueDate == nil && attempt.key == "\(id.uuidString.lowercased())/finished")
            }
        }
    }
}

enum PanelCurrency {
    // Local supported ISO4217 list; no network metadata or binary money conversion.
    static let minorUnits: [String: Int] = ["KRW":0, "USD":2, "EUR":2, "JPY":0, "GBP":2, "CNY":2, "CAD":2, "AUD":2, "CHF":2, "HKD":2, "SGD":2, "INR":2, "NZD":2, "TWD":2, "THB":2, "VND":0]
}
