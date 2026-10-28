import Foundation

struct CatalogCity: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var nameEN: String
    var nameKO: String
    var timeZone: String
    var latitude: Double
    var longitude: Double
    var aliases: [String]
}
struct CityCatalog: Sendable {
    let cities: [CatalogCity]
    init(data: Data) throws {
        guard data.count <= 262144 else { throw ExternalFailure.invalidResponse }
        let values = try JSONDecoder().decode([CatalogCity].self,from:data)
        guard !values.isEmpty, values.count <= 256, Set(values.map(\.id)).count == values.count,
              Set(values.map(\.timeZone)).count == values.count else { throw ExternalFailure.invalidResponse }
        for city in values {
            guard !city.id.isEmpty, city.id.count <= 80, city.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !city.nameEN.isEmpty, !city.nameKO.isEmpty, city.nameEN.count <= 100, city.nameKO.count <= 100,
                  city.timeZone.contains("/"), !city.timeZone.hasPrefix("Etc/"), TimeZone(identifier:city.timeZone) != nil,
                  city.latitude.isFinite, city.longitude.isFinite, (-90...90).contains(city.latitude), (-180...180).contains(city.longitude),
                  abs(city.latitude * 10000 - (city.latitude * 10000).rounded()) < 0.000001,
                  abs(city.longitude * 10000 - (city.longitude * 10000).rounded()) < 0.000001,
                  Set(city.aliases.map {$0.lowercased()}).count == city.aliases.count,
                  city.aliases.allSatisfy({ !$0.isEmpty && $0.count <= 100 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) && (!$0.contains("/") || TimeZone(identifier:$0) != nil) }) else { throw ExternalFailure.invalidResponse }
        }
        cities = values
    }
    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource:"Cities",withExtension:"json") else { throw ExternalFailure.invalidResponse }
        try self.init(data:Data(contentsOf:url))
    }
    func city(_ id: String) -> CatalogCity? { cities.first {$0.id == id} }
    var validIDs: Set<String> { Set(cities.map(\.id)) }
    func search(_ query: String) -> [CatalogCity] {
        guard query.count <= 100 else { return [] }
        let needle = query.trimmingCharacters(in:.whitespacesAndNewlines).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        guard !needle.isEmpty else { return cities }
        return cities.filter { city in
            ([city.nameEN,city.nameKO,city.id] + city.aliases).contains { $0.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).contains(needle) }
        }
    }
    func defaultCityID(timeZone: TimeZone) -> String? {
        let name = timeZone.identifier
        guard name.contains("/"), !name.hasPrefix("Etc/") else { return nil }
        return cities.first { $0.timeZone == name || $0.aliases.contains(name) }?.id
    }
}
