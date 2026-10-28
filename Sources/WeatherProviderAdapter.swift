import Foundation

enum WeatherProviderAdapter {
    static let freshSeconds:TimeInterval=10800
    static let staleSeconds:TimeInterval=86400
    static let optionsVersion=1
    static let maximumForecastDays=16
    static let attribution=ExternalAttribution(providerID:"open-meteo",labelKey:"weather.credit_label",sourceURL:"https://open-meteo.com/",licenseURL:"https://creativecommons.org/licenses/by/4.0/",transformationKey:"weather.transformation")
    private static let host="api.open-meteo.com"
    private static let path="/v1/forecast"
    static func cacheKey(latitude:Double,longitude:Double)->String {
        "\(attribution.providerID)/\(String(format:"%.4f",locale:Locale(identifier:"en_US_POSIX"),latitude))/\(String(format:"%.4f",locale:Locale(identifier:"en_US_POSIX"),longitude))/\(optionsVersion)"
    }
    static func request(city:CatalogCity,headers:ExternalHeaders=ExternalHeaders()) throws -> ExternalRequest {
        guard city.latitude.isFinite,city.longitude.isFinite,(-90...90).contains(city.latitude),(-180...180).contains(city.longitude) else {throw ExternalFailure.invalidResponse}
        var components=URLComponents();components.scheme="https";components.host=host;components.path=path
        components.queryItems=[URLQueryItem(name:"latitude",value:String(format:"%.4f",locale:Locale(identifier:"en_US_POSIX"),city.latitude)),URLQueryItem(name:"longitude",value:String(format:"%.4f",locale:Locale(identifier:"en_US_POSIX"),city.longitude)),URLQueryItem(name:"daily",value:"weather_code"),URLQueryItem(name:"forecast_days",value:String(maximumForecastDays)),URLQueryItem(name:"timezone",value:"auto")]
        guard let url=components.url else {throw ExternalFailure.invalidResponse}
        return ExternalRequest(kind:.weather,key:cacheKey(latitude:city.latitude,longitude:city.longitude),url:url,allowedHost:host,allowedPath:path,headers:headers)
    }
    static func parse(_ data:Data,city:CatalogCity,now:Instant,headers:ExternalHeaders) throws -> CachedWeather {
        guard !data.isEmpty,data.count<=ExternalBodyBuffer.maximumBytes else {throw ExternalFailure.invalidResponse}
        struct Response:Decodable {
            var timezone:String
            var daily:Daily
            struct Daily:Decodable {var time:[DateOnly];var weather_code:[Int]}
        }
        do {
            let response=try JSONDecoder().decode(Response.self,from:data)
            guard !response.daily.time.isEmpty,response.daily.time.count<=maximumForecastDays,response.daily.time.count==response.daily.weather_code.count,Set(response.daily.time).count==response.daily.time.count else {throw ExternalFailure.invalidResponse}
            let days=zip(response.daily.time,response.daily.weather_code).map{CachedWeatherDay(date:$0,code:$1)}.sorted{$0.date<$1.date}
            let value=CachedWeather(provider:attribution.providerID,cityID:city.id,latitude:city.latitude,longitude:city.longitude,optionsVersion:optionsVersion,fetchedAt:now,expiresAt:now.adding(seconds:freshSeconds),staleUntil:now.adding(seconds:staleSeconds),sourceTimeZone:response.timezone,days:days,etag:headers.etag,lastModified:headers.lastModified)
            try value.validate();return value
        } catch {throw ExternalFailure.invalidResponse}
    }
    static func revalidate(_ cache:CachedWeather,city:CatalogCity,now:Instant,headers:ExternalHeaders) throws -> CachedWeather {
        try cache.validate()
        guard cache.key==cacheKey(latitude:city.latitude,longitude:city.longitude),cache.cityID==city.id else {throw ExternalFailure.invalidResponse}
        var value=cache;value.fetchedAt=now;value.expiresAt=now.adding(seconds:freshSeconds);value.staleUntil=now.adding(seconds:staleSeconds)
        value.etag=headers.etag ?? value.etag;value.lastModified=headers.lastModified ?? value.lastModified
        return value
    }
    static func display(code:Int)->(emoji:String?,labelKey:String?) {
        switch code {
        case 0:return ("☀️","weather.clear")
        case 1:return ("🌤️","weather.partly_cloudy")
        case 2:return ("⛅️","weather.partly_cloudy")
        case 3:return ("☁️","weather.overcast")
        case 45,48:return ("🌫️","weather.fog")
        case 51,53,55,56,57:return ("🌦️","weather.drizzle")
        case 61,63,65,66,67,80,81,82:return ("🌧️","weather.rain")
        case 71,73,75,77,85,86:return ("🌨️","weather.snow")
        case 95,96,99:return ("⛈️","weather.thunderstorm")
        default:return (nil,nil)
        }
    }
}
