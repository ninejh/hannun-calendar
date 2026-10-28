import Foundation

/// Display-only civil-time formatting. No stored dates or domain state are changed here.
struct WorldClockReading: Equatable {
    var timeText: String
    var offsetMinutes: Int
    var isDay: Bool
    var day: DateOnly
    init?(city: CatalogCity, now: Instant, macTimeZone: String) {
        let date = now.date
        guard let zone = TimeZone(identifier: city.timeZone), let mac = TimeZone(identifier: macTimeZone),
              let day = DateOnly(date: date, timeZone: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = parts.hour ?? 0
        timeText = String(format: "%02d:%02d:%02d", hour, parts.minute ?? 0, parts.second ?? 0)
        offsetMinutes = (zone.secondsFromGMT(for: date) - mac.secondsFromGMT(for: date)) / 60
        isDay = (6..<18).contains(hour); self.day = day
    }
}
