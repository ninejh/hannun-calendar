import Foundation

enum RateProviderAdapter {
    static let freshSeconds:TimeInterval=86400
    static let attribution=ExternalAttribution(providerID:"frankfurter-ecb",labelKey:"rates.credit_label",sourceURL:"https://frankfurter.dev/",licenseURL:"https://www.ecb.europa.eu/services/using-our-site/disclaimer/html/index.en.html",transformationKey:"rates.transformation")
    private static let host="api.frankfurter.dev"
    private static let path="/v2/providers/ecb/rates"
    static let supportedQuotes:Set<String>=["EUR","USD","JPY","KRW","GBP","CNY","CAD","AUD","CHF","HKD","SGD","INR","NZD","THB"]
    static func quotes(currencies:Set<String>)->[String] {Array(currencies.intersection(supportedQuotes).union(["KRW"])).sorted()}
    static func cacheKey(quotes:[String])->String {"\(attribution.providerID)/EUR/\(quotes.sorted().joined(separator:","))"}
    static func request(currencies:Set<String>,headers:ExternalHeaders=ExternalHeaders()) throws -> ExternalRequest {
        let desired=quotes(currencies:currencies)
        var c=URLComponents();c.scheme="https";c.host=host;c.path=path
        c.queryItems=[URLQueryItem(name:"base",value:"EUR"),URLQueryItem(name:"quotes",value:desired.joined(separator:","))]
        guard let url=c.url else {throw ExternalFailure.invalidResponse}
        return ExternalRequest(kind:.rates,key:cacheKey(quotes:desired),url:url,allowedHost:host,allowedPath:path,headers:headers)
    }
    /// External JSON number lexemes are quoted before JSONSerialization can convert them to binary Double.
    private static func losslessNumbers(_ data:Data) throws -> Data {
        let bytes=Array(data);var output=[UInt8]();output.reserveCapacity(bytes.count)
        var i=0,quoted=false,escaped=false
        while i<bytes.count {
            let byte=bytes[i]
            if quoted {
                output.append(byte)
                if escaped {escaped=false} else if byte==92 {escaped=true} else if byte==34 {quoted=false}
                i+=1;continue
            }
            if byte==34 {quoted=true;output.append(byte);i+=1;continue}
            if byte==45 || (48...57).contains(byte) {
                let start=i
                while i<bytes.count && ((48...57).contains(bytes[i]) || [45,43,46,69,101].contains(bytes[i])) {i+=1}
                guard i-start<=96 else {throw ExternalFailure.invalidResponse}
                let token=String(decoding:bytes[start..<i],as:UTF8.self)
                guard token.range(of:#"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil else {throw ExternalFailure.invalidResponse}
                output.append(34);output.append(contentsOf:bytes[start..<i]);output.append(34)
            } else {output.append(byte);i+=1}
        }
        return Data(output)
    }
    static func decimal(_ text:String) throws -> Decimal {
        guard text.count<=96,text.range(of:#"^(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,
              let result=Decimal(string:text,locale:ExactDecimal.locale),!result.isNaN,result>0,result<ExactDecimal.limit else {throw ExternalFailure.invalidResponse}
        // Decimal silently rounds oversized significands; external coefficients are bounded before parsing.
        let significand=text.split(whereSeparator:{$0=="e" || $0=="E"})[0].filter{$0 != "."}.drop(while:{$0=="0"})
        guard significand.count<=37 else {throw ExternalFailure.invalidResponse}
        return result
    }
    private static func canonical(_ value:Decimal)->String {var value=value;return NSDecimalString(&value,ExactDecimal.locale)}
    private static func pair(krw:Decimal,quote:Decimal) throws -> String {
        // Integer quotient/remainder rounding; an inexact quotient never decides a half boundary.
        let numerator=try ExactDecimal.multiply(krw,100_000_000)
        var a=numerator,b=quote,division=Decimal()
        let status=NSDecimalDivide(&division,&a,&b,.down)
        guard status == .noError || status == .lossOfPrecision,!division.isNaN else {throw ExternalFailure.invalidResponse}
        var whole=Decimal();NSDecimalRound(&whole,&division,0,.down)
        guard whole>=0,whole<10_000_000_000_000_000 else {throw ExternalFailure.invalidResponse}
        func subtract(_ lhs:Decimal,_ rhs:Decimal) throws -> Decimal {
            var lhs=lhs,rhs=rhs,value=Decimal()
            guard NSDecimalSubtract(&value,&lhs,&rhs,.plain) == .noError,!value.isNaN,value > -ExactDecimal.limit,value < ExactDecimal.limit else {throw ExternalFailure.invalidResponse}
            return value
        }
        var remainder=try subtract(numerator,ExactDecimal.multiply(whole,quote))
        if remainder<0 {whole=try subtract(whole,1);remainder=try ExactDecimal.add(remainder,quote)}
        if remainder>=quote {whole=try ExactDecimal.add(whole,1);remainder=try subtract(remainder,quote)}
        guard remainder>=0,remainder<quote else {throw ExternalFailure.invalidResponse}
        if remainder >= (try subtract(quote,remainder)) {whole=try ExactDecimal.add(whole,1)}
        guard whole>0,whole<10_000_000_000_000_000 else {throw ExternalFailure.invalidResponse}
        var digits=canonical(whole)
        guard digits.utf8.allSatisfy({(48...57).contains($0)}) else {throw ExternalFailure.invalidResponse}
        if digits.count<=8 {digits=String(repeating:"0",count:9-digits.count)+digits}
        digits.insert(".",at:digits.index(digits.endIndex,offsetBy:-8))
        return digits
    }
    static func parse(_ data:Data,quotes:[String],now:Instant,headers:ExternalHeaders,previous:CachedRates?) throws -> CachedRates {
        guard !data.isEmpty,data.count<=ExternalBodyBuffer.maximumBytes else {throw ExternalFailure.invalidResponse}
        do {
            guard let rows=try JSONSerialization.jsonObject(with:losslessNumbers(data)) as? [[String:Any]],!rows.isEmpty,rows.count<=64 else {throw ExternalFailure.invalidResponse}
            var entries=[CachedRateQuote](),seen=Set<String>()
            for row in rows {
                guard row["base"] as? String=="EUR",let quote=row["quote"] as? String,supportedQuotes.contains(quote),quotes.contains(quote),seen.insert(quote).inserted,
                      let date=row["date"] as? String,let day=DateOnly(date),let raw=row["rate"] as? String else {throw ExternalFailure.invalidResponse}
                entries.append(CachedRateQuote(quote:quote,rate:canonical(try decimal(raw)),rateDate:day))
            }
            return try normalized(entries:entries,quotes:quotes,now:now,headers:headers,previous:previous)
        } catch {throw ExternalFailure.invalidResponse}
    }
    private static func normalized(entries:[CachedRateQuote],quotes:[String],now:Instant,headers:ExternalHeaders,previous:CachedRates?) throws -> CachedRates {
        var pairs=Dictionary(uniqueKeysWithValues:(previous?.pairs ?? []).map{($0.currency,$0)})
        if let krw=entries.first(where:{$0.quote=="KRW"}) {
            let krwRate=try decimal(krw.rate)
            for currency in quotes where currency != "KRW" {
                let quote:Decimal
                if currency=="EUR" {quote=1}
                else {
                    guard let value=entries.first(where:{$0.quote==currency && $0.rateDate==krw.rateDate}) else {continue}
                    quote=try decimal(value.rate)
                }
                pairs[currency]=PanelRatePair(currency:currency,krwPerUnit:try pair(krw:krwRate,quote:quote),rateDate:krw.rateDate,fetchedAt:now)
            }
        }
        let value=CachedRates(provider:attribution.providerID,base:"EUR",quotes:quotes.sorted(),fetchedAt:now,expiresAt:now.adding(seconds:freshSeconds),entries:entries.sorted{$0.quote<$1.quote},pairs:pairs.values.sorted{$0.currency<$1.currency},etag:headers.etag,lastModified:headers.lastModified)
        try value.validate();return value
    }
    static func revalidate(_ cache:CachedRates,quotes:[String],now:Instant,headers:ExternalHeaders) throws -> CachedRates {
        try cache.validate()
        guard cache.key==cacheKey(quotes:quotes) else {throw ExternalFailure.invalidResponse}
        return try normalized(entries:cache.entries,quotes:quotes,now:now,headers:ExternalHeaders(etag:headers.etag ?? cache.etag,lastModified:headers.lastModified ?? cache.lastModified),previous:cache)
    }
}
