import Foundation

struct PanelDomainError: Error, Equatable, Sendable {
    enum Code: String, Sendable {
        case validationFailed = "VALIDATION_FAILED", boardConflict = "BOARD_CONFLICT", dayChanged = "DAY_CHANGED"
        case cityLimit = "CITY_LIMIT", cityNotFound = "CITY_NOT_FOUND", panelNotAssigned = "PANEL_NOT_ASSIGNED"
        case invalidResponse = "INVALID_RESPONSE"
    }
    var code: Code
    var field: String? = nil
}

struct SubscriptionInput: Sendable {
    var id: UUID
    var name: String
    var nextDate: DateOnly
    var cycle: SubscriptionCycle
    var amount: String
    var currency: String
    var paymentMemo: String = ""
}
struct SubscriptionPatch: Sendable {
    var name: String? = nil
    var nextDate: DateOnly? = nil
    var cycle: SubscriptionCycle? = nil
    var amount: String? = nil
    var currency: String? = nil
    var paymentMemo: String? = nil
    var isEmpty: Bool { name == nil && nextDate == nil && cycle == nil && amount == nil && currency == nil && paymentMemo == nil }
}
struct TodoPatch: Sendable {
    var title: String? = nil
    var completed: Bool? = nil
}
enum PanelIntent: Sendable {
    case selectSlot(SlotID, PanelID), setSlotVisible(SlotID, Bool), setPanelVisible(PanelID, Bool), revealAgenda, resetLayout
    case createSubscription(SubscriptionInput), updateSubscription(UUID, SubscriptionPatch), deleteSubscription(UUID)
    case createTodo(UUID, String), updateTodo(UUID, TodoPatch), deleteTodo(UUID)
    case createHabit(UUID, String), updateHabit(UUID, String), setHabitToday(UUID, Bool, DateOnly), deleteHabit(UUID)
    case addCity(String), deleteCity(String)
}
struct PanelDeletedRefs: Equatable, Sendable {
    var subscriptions: [UUID] = []
    var todos: [UUID] = []
    var habits: [UUID] = []
    var cityIDs: [String] = []
}

/// Inverses retain complete records, including private native fields and original array indices.
/// Only fields touched by this mutation are restored; operational ledgers are never rewound.
struct PanelMutation: Sendable {
    let before: BoardState
    let state: BoardState
    var deletedRefs = PanelDeletedRefs()
    var revealedSlotID: SlotID? = nil
    var changed: Bool { before != state }
    func undo(on current: BoardState) throws -> BoardState {
        var next = current
        func restore<T: Equatable>(_ key: WritableKeyPath<BoardState, T>) throws {
            guard before[keyPath: key] != state[keyPath: key] else { return }
            guard current[keyPath: key] == state[keyPath: key] else { throw PanelDomainError(code: .boardConflict) }
            next[keyPath: key] = before[keyPath: key]
        }
        try restore(\.layout); try restore(\.subscriptions); try restore(\.todos)
        try restore(\.habits); try restore(\.worldClockCities)
        try next.validate()
        return next
    }
}

enum PanelDomain {
    static func apply(_ intent: PanelIntent, to state: BoardState, now: Instant, today: DateOnly,
                      validCityIDs: Set<String> = []) throws -> PanelMutation {
        var next = state
        var deleted = PanelDeletedRefs()
        var revealed: SlotID?
        func title(_ raw: String, field: String = "title") throws -> String {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 500 else { throw PanelDomainError(code: .validationFailed, field: field) }
            return value
        }
        func index<T: Identifiable>(_ values: [T], _ id: T.ID) throws -> Int {
            guard let index = values.firstIndex(where: { $0.id == id }) else { throw PanelDomainError(code: .boardConflict) }
            return index
        }
        func unique<T: Identifiable>(_ values: [T], _ id: T.ID) throws {
            guard !values.contains(where: { $0.id == id }) else { throw PanelDomainError(code: .boardConflict) }
        }
        func select(_ slot: SlotID, _ panel: PanelID) {
            let old = next.layout.slots[slot.rawValue]!
            guard old != panel else { return }
            if let other = next.layout.slots.first(where: { $0.value == panel })?.key { next.layout.slots[other] = old }
            next.layout.slots[slot.rawValue] = panel
        }
        try state.validate()
        switch intent {
        case let .selectSlot(slot, panel): select(slot, panel)
        case let .setSlotVisible(slot, visible):
            if visible { next.layout.hiddenSlots.remove(slot.rawValue) } else { next.layout.hiddenSlots.insert(slot.rawValue) }
        case let .setPanelVisible(panel, visible):
            guard BoardLayout.panelNames.contains(panel.rawValue), let slot = next.layout.slots.first(where: { $0.value == panel })?.key else {
                throw PanelDomainError(code: .panelNotAssigned)
            }
            if visible { next.layout.hiddenSlots.remove(slot) } else { next.layout.hiddenSlots.insert(slot) }
        case .revealAgenda:
            let slot = next.layout.slots.first(where: { $0.value == .today }).flatMap { SlotID(rawValue: $0.key) } ?? .railTop
            select(slot, .today); next.layout.hiddenSlots.remove(slot.rawValue); revealed = slot
        case .resetLayout:
            next.layout.resetSizes()
        case let .createSubscription(input):
            try unique(next.subscriptions, input.id)
            try validateSubscription(amount:input.amount,currency:input.currency,paymentMemo:input.paymentMemo)
            next.subscriptions.append(Subscription(id: input.id, name: try title(input.name, field:"name"), nextDate: input.nextDate,
                cycle: input.cycle, amount: input.amount, currency: input.currency, paymentMemo: input.paymentMemo,
                anchorDate: input.nextDate, scheduleID: UUID()))
        case let .updateSubscription(id, patch):
            guard !patch.isEmpty else { throw PanelDomainError(code: .validationFailed) }
            let i = try index(next.subscriptions, id)
            var value = next.subscriptions[i]
            let changedSchedule = (patch.nextDate != nil && patch.nextDate != value.nextDate) || (patch.cycle != nil && patch.cycle != value.cycle)
            if let name = patch.name { value.name = try title(name, field:"name") }
            if let date = patch.nextDate { value.nextDate = date }
            if let cycle = patch.cycle { value.cycle = cycle }
            if let amount = patch.amount { value.amount = amount }
            if let currency = patch.currency { value.currency = currency }
            if let memo = patch.paymentMemo { value.paymentMemo = memo }
            if changedSchedule { value.anchorDate = value.nextDate; value.scheduleID = UUID() }
            try validateSubscription(amount:value.amount,currency:value.currency,paymentMemo:value.paymentMemo)
            next.subscriptions[i] = value
        case let .deleteSubscription(id):
            next.subscriptions.remove(at: try index(next.subscriptions, id)); deleted.subscriptions = [id]
        case let .createTodo(id, raw):
            try unique(next.todos, id); next.todos.append(Todo(id: id, title: try title(raw), createdAt: now))
        case let .updateTodo(id, patch):
            guard patch.title != nil || patch.completed != nil else { throw PanelDomainError(code: .validationFailed) }
            let i = try index(next.todos, id)
            if let raw = patch.title { next.todos[i].title = try title(raw) }
            if let completed = patch.completed, next.todos[i].completed != completed {
                next.todos[i].completed = completed; next.todos[i].completedAt = completed ? now : nil
            }
        case let .deleteTodo(id): next.todos.remove(at: try index(next.todos, id)); deleted.todos = [id]
        case let .createHabit(id, raw):
            try unique(next.habits, id); next.habits.append(Habit(id: id, title: try title(raw), createdOn: today))
        case let .updateHabit(id, raw): next.habits[try index(next.habits, id)].title = try title(raw)
        case let .setHabitToday(id, checked, expectedToday):
            guard today == expectedToday else { throw PanelDomainError(code: .dayChanged) }
            let i = try index(next.habits, id)
            var marks = Set(next.habits[i].marks)
            if checked { marks.insert(today) } else { marks.remove(today) }
            next.habits[i].marks = marks.sorted()
        case let .deleteHabit(id): next.habits.remove(at: try index(next.habits, id)); deleted.habits = [id]
        case let .addCity(city):
            guard validCityIDs.contains(city) else { throw PanelDomainError(code: .cityNotFound) }
            if !next.worldClockCities.contains(where: { $0.id == city }) {
                guard next.worldClockCities.count < 4 else { throw PanelDomainError(code: .cityLimit) }
                next.worldClockCities.append(WorldClockCity(id: city))
            }
        case let .deleteCity(city):
            guard let i = next.worldClockCities.firstIndex(where: { $0.id == city }) else { throw PanelDomainError(code: .cityNotFound) }
            next.worldClockCities.remove(at: i); deleted.cityIDs = [city]
        }
        do { try next.validate() }
        catch { throw PanelDomainError(code: .validationFailed) }
        return PanelMutation(before: state, state: next, deletedRefs: deleted, revealedSlotID: revealed)
    }

    private static func validateSubscription(amount: String, currency: String, paymentMemo: String) throws {
        guard PanelCurrency.minorUnits[currency] != nil else { throw PanelDomainError(code:.validationFailed,field:"currency") }
        guard paymentMemo.count <= 4096 else { throw PanelDomainError(code:.validationFailed,field:"paymentMemo") }
        do { _ = try ExactDecimal.scaled(amount,integerDigits:12,scale:4) }
        catch { throw PanelDomainError(code:.validationFailed,field:"amount") }
    }

    static func streak(_ marks: [DateOnly], today: DateOnly) -> Int {
        let days = Set(marks.filter { $0 <= today }.map(\.ordinal))
        var day = days.contains(today.ordinal) ? today.ordinal : today.ordinal - 1
        var count = 0
        while days.contains(day) { count += 1; day -= 1 }
        return count
    }
    static func recentDays(today: DateOnly) -> [DateOnly] { (-6...0).compactMap { today.addingDays($0) } }
    static func displaySubscriptions(_ values: [Subscription]) -> [Subscription] {
        values.enumerated().sorted { a, b in a.element.nextDate == b.element.nextDate ? a.offset < b.offset : a.element.nextDate < b.element.nextDate }.map(\.element)
    }
    static func rollover(anchor: DateOnly, nextDate: DateOnly, cycle: SubscriptionCycle, today: DateOnly) throws -> DateOnly {
        guard nextDate < today else { return nextDate }
        guard anchor <= nextDate else { throw PanelDomainError(code: .validationFailed, field: "nextDate") }
        if cycle == .weekly {
            let n = max(0, (today.ordinal - anchor.ordinal + 6) / 7)
            guard let result = anchor.addingDays(n * 7) else { throw PanelDomainError(code: .validationFailed, field: "nextDate") }
            return result
        }
        var offset = cycle == .monthly ? (today.year - anchor.year) * 12 + today.month - anchor.month : today.year - anchor.year
        func occurrence(_ offset: Int) -> DateOnly? {
            let monthIndex = anchor.year * 12 + anchor.month - 1 + (cycle == .monthly ? offset : offset * 12)
            let year = monthIndex / 12, month = monthIndex % 12 + 1
            guard (1...9999).contains(year) else { return nil }
            for day in stride(from: anchor.day, through: 28, by: -1) {
                if let value = DateOnly(String(format: "%04d-%02d-%02d", year, month, day)) { return value }
            }
            return DateOnly(String(format: "%04d-%02d-%02d", year, month, anchor.day))
        }
        guard var result = occurrence(max(0, offset)) else { throw PanelDomainError(code: .validationFailed, field: "nextDate") }
        if result < today {
            offset += 1
            guard let later = occurrence(offset) else { throw PanelDomainError(code: .validationFailed, field: "nextDate") }
            result = later
        }
        return result
    }
    static func rolloverSubscriptions(_ state: BoardState, today: DateOnly) throws -> BoardState {
        var next = state
        for i in next.subscriptions.indices {
            let value = next.subscriptions[i]
            next.subscriptions[i].nextDate = try rollover(anchor: value.anchorDate, nextDate: value.nextDate, cycle: value.cycle, today: today)
        }
        try next.validate(); return next
    }
}

extension DateOnly {
    /// Ordinal arithmetic is independent of DST, local time and 86400-second durations.
    func addingDays(_ count: Int) -> DateOnly? {
        let sum = ordinal.addingReportingOverflow(count)
        guard !sum.overflow, (1...3_652_059).contains(sum.partialValue) else { return nil }
        let target = sum.partialValue
        var lower = 1, upper = 9999
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            let first = DateOnly(String(format: "%04d-01-01", middle))!
            if first.ordinal <= target { lower = middle } else { upper = middle - 1 }
        }
        for month in 1...12 {
            for day in 1...31 {
                if let value = DateOnly(String(format: "%04d-%02d-%02d", lower, month, day)), value.ordinal == target { return value }
            }
        }
        return nil
    }
}

struct PanelMetadata: Codable, Equatable, Sendable {
    var currencyMinorUnits = PanelCurrency.minorUnits
    var amountScale = 4
    var fxScale = 8
    var rounding = "halfUp"
    var accumulatorMaxDigits = 37
}
enum PanelExternalState: String, Codable, Sendable { case fresh, stale, unavailable, off, loading }
struct PanelRatePair: Codable, Equatable, Sendable {
    var currency: String
    var krwPerUnit: String
    var rateDate: DateOnly
    var fetchedAt: Instant
}
struct PanelRates: Codable, Equatable, Sendable {
    var state: PanelExternalState = .unavailable
    var entries: [PanelRatePair] = []
}
struct MonthlySubscription: Codable, Equatable, Sendable {
    var amount: String
    var currency: String
    var cycle: SubscriptionCycle
}
struct SubscriptionSummary: Codable, Equatable, Sendable {
    struct CurrencyTotal: Codable, Equatable, Sendable { var currency: String; var monthlyAmount: String }
    var byCurrency: [CurrencyTotal]
    var krwMonthlyAmount: String?
    var complete: Bool
    var missingCurrencies: [String]
    var rateDates: [DateOnly]
    var fetchedAt: Instant?
    var state: PanelExternalState
    var oldestPairFetchedAt: Instant?
}

enum PanelMath {
    static func reduceSubscriptions(_ subscriptions: [Subscription], rates: PanelRates, metadata: PanelMetadata = PanelMetadata(), now: Instant? = nil) throws -> SubscriptionSummary {
        try reduceSubscriptions(subscriptions.map { MonthlySubscription(amount: $0.amount, currency: $0.currency, cycle: $0.cycle) }, rates: rates, metadata: metadata, now: now)
    }
    static func reduceSubscriptions(_ subscriptions: [MonthlySubscription], rates: PanelRates, metadata: PanelMetadata = PanelMetadata(), now: Instant? = nil) throws -> SubscriptionSummary {
        guard metadata.amountScale == 4, metadata.fxScale == 8, metadata.rounding == "halfUp", metadata.accumulatorMaxDigits == 37,
              metadata.currencyMinorUnits.values.allSatisfy({ (0...4).contains($0) }) else { throw PanelDomainError(code: .validationFailed, field: "metadata") }
        var pairs: [String: PanelRatePair] = [:]
        for pair in rates.entries {
            guard metadata.currencyMinorUnits[pair.currency] != nil, pairs[pair.currency] == nil, pair.currency != "KRW" else { throw PanelDomainError(code: .invalidResponse) }
            do { guard try ExactDecimal.scaled(pair.krwPerUnit, integerDigits: 8, scale: 8) > 0 else { throw BoardStorageError(.invalidData) } }
            catch { throw PanelDomainError(code: .invalidResponse) }
            pairs[pair.currency] = pair
        }
        var totals: [String: Decimal] = [:]
        var krw: Decimal = 0
        var converted = subscriptions.isEmpty
        var missing = Set<String>(), dates = Set<DateOnly>()
        var oldest: Instant?
        for subscription in subscriptions {
            guard metadata.currencyMinorUnits[subscription.currency] != nil else { throw PanelDomainError(code: .validationFailed, field: "currency") }
            let numerator: Decimal
            do {
                let amount = try ExactDecimal.scaled(subscription.amount, integerDigits: 12, scale: 4)
                let factor = Decimal(subscription.cycle == .monthly ? 12 : subscription.cycle == .weekly ? 52 : 1)
                numerator = try ExactDecimal.multiply(amount, factor)
                totals[subscription.currency] = try ExactDecimal.add(totals[subscription.currency] ?? 0, numerator)
            } catch { throw PanelDomainError(code: .validationFailed, field: "amount") }
            if subscription.currency == "KRW" {
                do { krw = try ExactDecimal.add(krw, ExactDecimal.multiply(numerator, 100_000_000)); converted = true }
                catch { throw PanelDomainError(code: .validationFailed, field: "amount") }
            } else if let pair = pairs[subscription.currency] {
                do {
                    let fx = try ExactDecimal.scaled(pair.krwPerUnit, integerDigits: 8, scale: 8)
                    krw = try ExactDecimal.add(krw, ExactDecimal.multiply(numerator, fx)); converted = true
                } catch { throw PanelDomainError(code: .invalidResponse) }
                dates.insert(pair.rateDate); oldest = min(oldest ?? pair.fetchedAt, pair.fetchedAt)
            } else { missing.insert(subscription.currency) }
        }
        let currencies = try totals.keys.sorted().map { currency in
            SubscriptionSummary.CurrencyTotal(currency: currency, monthlyAmount: try rounded(totals[currency]!, denominator: 120_000, minorUnits: metadata.currencyMinorUnits[currency]!))
        }
        let state: PanelExternalState
        if rates.state == .off { state = .off }
        else if let oldest {
            let expired = now.map { $0.date.timeIntervalSince(oldest.date) >= 86_400 } ?? false
            state = expired || rates.state == .stale || rates.state == .unavailable ? .stale : .fresh
        } else { state = missing.isEmpty ? .fresh : .unavailable }
        return SubscriptionSummary(byCurrency: currencies,
            krwMonthlyAmount: converted ? try rounded(krw, denominator: 12_000_000_000_000, minorUnits: 0) : nil,
            complete: missing.isEmpty, missingCurrencies: missing.sorted(), rateDates: dates.sorted(), fetchedAt: oldest,
            state: state, oldestPairFetchedAt: oldest)
    }
    /// Integer coefficient -> long division -> one half-up rounding. No intermediate money rounding.
    private static func rounded(_ numerator: Decimal, denominator: UInt64, minorUnits: Int) throws -> String {
        var value = numerator
        let digits = NSDecimalString(&value, ExactDecimal.locale)
        guard digits.utf8.allSatisfy({ (48...57).contains($0) }) else { throw PanelDomainError(code: .invalidResponse) }
        let power: UInt64 = [1,10,100,1000,10000][minorUnits]
        guard denominator % power == 0 else { throw PanelDomainError(code: .invalidResponse) }
        let divisor = denominator / power
        var remainder: UInt64 = 0
        var quotient = ""
        for digit in digits.utf8 {
            remainder = remainder * 10 + UInt64(digit - 48)
            quotient.append(String(remainder / divisor)); remainder %= divisor
        }
        quotient = String(quotient.drop(while: { $0 == "0" }))
        if quotient.isEmpty { quotient = "0" }
        if remainder * 2 >= divisor {
            var bytes = Array(quotient.utf8)
            var carry = true
            for i in bytes.indices.reversed() {
                guard carry else { break }
                if bytes[i] == 57 { bytes[i] = 48 } else { bytes[i] += 1; carry = false }
            }
            if carry { bytes.insert(49, at: 0) }
            quotient = String(decoding: bytes, as: UTF8.self)
        }
        guard minorUnits > 0 else { return quotient }
        if quotient.count <= minorUnits { quotient = String(repeating: "0", count: minorUnits + 1 - quotient.count) + quotient }
        let point = quotient.index(quotient.endIndex, offsetBy: -minorUnits)
        quotient.insert(".", at: point)
        return quotient
    }
}
