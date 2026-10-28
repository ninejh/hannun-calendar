import Foundation
import CryptoKit

extension Instant {
    func adding(seconds: TimeInterval) -> Instant { Instant(date:date.addingTimeInterval(seconds)) }
}
struct SidecarStorageError: Error { var committed: Bool }
@MainActor protocol SidecarPersistence {
    func read() throws -> Data?
    func write(_ value: Data, exclusive: Bool) throws
    func preserveCurrent() throws
}
/// Sidecars never touch board.json; callers provide only native-owned/scratch destinations.
@MainActor final class PrivateSidecarFile: SidecarPersistence {
    let url: URL
    enum Phase {case beforeWrite,afterReplace}
    var fault: ((Phase) throws -> Void)?
    init(url:URL,fault:((Phase)throws->Void)? = nil){self.url=url;self.fault=fault}
    private func exists() throws -> Bool {
        guard url.isFileURL,url.path.hasPrefix("/"),!url.pathComponents.contains(".."),!url.pathComponents.contains(".") else {throw SidecarStorageError(committed:false)}
        var path=url,found=false
        while path.path != "/" {
            var info=stat()
            if lstat(path.path,&info)==0 {
                guard info.st_mode & S_IFMT == (path == url ? S_IFREG : S_IFDIR) else {throw SidecarStorageError(committed:false)}
                if path == url {found=true}
            } else if errno != ENOENT {throw SidecarStorageError(committed:false)}
            path.deleteLastPathComponent()
        }
        return found
    }
    func read() throws -> Data? {
        guard try exists() else {return nil}
        return try bytes(url)
    }
    private func bytes(_ location:URL) throws -> Data {
        let fd=open(location.path,O_RDONLY|O_NOFOLLOW)
        guard fd >= 0 else {throw SidecarStorageError(committed:false)}
        defer {close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_uid == geteuid(),info.st_size <= 1_048_576 else {throw SidecarStorageError(committed:false)}
        if info.st_mode & 0o7777 != 0o600 {
            // Repair only our own unlinked-to-other-files regular descriptor; never replace budget bytes.
            guard info.st_nlink == 1, fchmod(fd,0o600)==0, fsync(fd)==0,
                  fstat(fd,&info)==0, info.st_mode & 0o7777 == 0o600 else {throw SidecarStorageError(committed:false)}
        }
        let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd() ?? Data()
        guard data.count <= 1_048_576 else {throw SidecarStorageError(committed:false)}
        return data
    }
    private func directory() throws -> Int32 {
        _ = try exists()
        let parent=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        _ = try exists()
        let fd=open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard fd >= 0 else {throw SidecarStorageError(committed:false)}
        guard fchmod(fd,0o700)==0 else {close(fd);throw SidecarStorageError(committed:false)}
        return fd
    }
    private func create(_ data:Data,name:String,directory:Int32) throws {
        let fd=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode_t(0o600))
        guard fd >= 0 else {throw SidecarStorageError(committed:false)}
        defer {close(fd)}
        guard fchmod(fd,0o600)==0 else {throw SidecarStorageError(committed:false)}
        try data.withUnsafeBytes { value in
            var offset=0
            while offset<value.count {
                let count=Darwin.write(fd,value.baseAddress!.advanced(by:offset),value.count-offset)
                if count<0 && errno==EINTR {continue}
                guard count>0 else {throw SidecarStorageError(committed:false)}
                offset+=count
            }
        }
        guard fsync(fd)==0 else {throw SidecarStorageError(committed:false)}
    }
    func write(_ data:Data,exclusive:Bool) throws {
        guard data.count <= 1_048_576 else {throw SidecarStorageError(committed:false)}
        try fault?(.beforeWrite)
        let fd=try directory();defer {close(fd)}
        let stage=".external-"+UUID().uuidString.lowercased()+".tmp"
        defer {unlinkat(fd,stage,0)}
        try create(data,name:stage,directory:fd)
        let staged=try bytes(url.deletingLastPathComponent().appendingPathComponent(stage))
        guard SHA256.hash(data:staged)==SHA256.hash(data:data) else {throw SidecarStorageError(committed:false)}
        _ = try exists()
        if exclusive {
            guard linkat(fd,stage,fd,url.lastPathComponent,0)==0 else {throw SidecarStorageError(committed:false)}
        } else {
            guard renameat(fd,stage,fd,url.lastPathComponent)==0 else {throw SidecarStorageError(committed:false)}
        }
        do {
            try fault?(.afterReplace)
            guard fsync(fd)==0,try bytes(url)==data else {throw SidecarStorageError(committed:true)}
        } catch {throw SidecarStorageError(committed:true)}
    }
    func preserveCurrent() throws {
        guard let data=try read() else {return}
        let fd=try directory();defer {close(fd)}
        let name=url.deletingPathExtension().lastPathComponent+".preserved-"+UUID().uuidString.lowercased()+".json"
        try create(data,name:name,directory:fd)
        guard try bytes(url.deletingLastPathComponent().appendingPathComponent(name))==data,fsync(fd)==0 else {throw SidecarStorageError(committed:false)}
    }
}
struct CachedWeatherDay: Codable, Equatable, Sendable { var date:DateOnly;var code:Int }
struct CachedWeather: Codable, Equatable, Sendable {
    var provider:String
    var cityID:String
    var latitude:Double
    var longitude:Double
    var optionsVersion:Int
    var fetchedAt:Instant
    var expiresAt:Instant
    var staleUntil:Instant
    var sourceTimeZone:String
    var days:[CachedWeatherDay]
    var etag:String?
    var lastModified:String?
    var key:String {WeatherProviderAdapter.cacheKey(latitude:latitude,longitude:longitude)}
    func validate() throws {
        guard provider==WeatherProviderAdapter.attribution.providerID,optionsVersion==WeatherProviderAdapter.optionsVersion,!cityID.isEmpty,
              latitude.isFinite,longitude.isFinite,(-90...90).contains(latitude),(-180...180).contains(longitude),
              abs(latitude*10000-(latitude*10000).rounded())<0.000001,abs(longitude*10000-(longitude*10000).rounded())<0.000001,
              expiresAt==fetchedAt.adding(seconds:WeatherProviderAdapter.freshSeconds),staleUntil==fetchedAt.adding(seconds:WeatherProviderAdapter.staleSeconds),TimeZone(identifier:sourceTimeZone) != nil,
              !days.isEmpty,days.count<=WeatherProviderAdapter.maximumForecastDays,Set(days.map(\.date)).count==days.count,days.map(\.date)==days.map(\.date).sorted(),
              days.allSatisfy({(0...999).contains($0.code)}),etag==ExternalHeaders.safe(etag),lastModified==ExternalHeaders.safe(lastModified) else {throw ExternalFailure.invalidResponse}
    }
}
struct CachedRateQuote: Codable, Equatable, Sendable {var quote:String;var rate:String;var rateDate:DateOnly}
struct CachedRates: Codable, Equatable, Sendable {
    var provider:String
    var base:String
    var quotes:[String]
    var fetchedAt:Instant
    var expiresAt:Instant
    var entries:[CachedRateQuote]
    var pairs:[PanelRatePair]
    var etag:String?
    var lastModified:String?
    var key:String {RateProviderAdapter.cacheKey(quotes:quotes)}
    func validate() throws {
        guard provider==RateProviderAdapter.attribution.providerID,base=="EUR",quotes==Array(Set(quotes)).sorted(),!quotes.isEmpty,
              quotes.allSatisfy({RateProviderAdapter.supportedQuotes.contains($0)}),expiresAt==fetchedAt.adding(seconds:RateProviderAdapter.freshSeconds),
              !entries.isEmpty,Set(entries.map(\.quote)).count==entries.count,Set(pairs.map(\.currency)).count==pairs.count,
              etag==ExternalHeaders.safe(etag),lastModified==ExternalHeaders.safe(lastModified) else {throw ExternalFailure.invalidResponse}
        for entry in entries {guard quotes.contains(entry.quote),try RateProviderAdapter.decimal(entry.rate)>0 else {throw ExternalFailure.invalidResponse}}
        for pair in pairs {
            guard PanelCurrency.minorUnits[pair.currency] != nil,pair.currency != "KRW",try ExactDecimal.scaled(pair.krwPerUnit,integerDigits:8,scale:8)>0 else {throw ExternalFailure.invalidResponse}
        }
    }
}
struct ExternalCacheState: Codable, Equatable, Sendable {
    var cacheVersion=1
    var weather:CachedWeather?=nil
    var rates:CachedRates?=nil
    func validate() throws {
        guard cacheVersion==1 else {throw ExternalFailure.invalidResponse}
        try weather?.validate();try rates?.validate()
    }
}
@MainActor final class ExternalCache {
    private(set) var state=ExternalCacheState()
    private let persistence:any SidecarPersistence
    init(persistence:any SidecarPersistence){
        self.persistence=persistence
        do {if let data=try persistence.read(){let value=try JSONDecoder().decode(ExternalCacheState.self,from:data);try value.validate();state=value}}
        catch {state=ExternalCacheState()}
    }
    func commit(_ next:ExternalCacheState) throws {
        try next.validate()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(next)
        try persistence.write(data,exclusive:false)
        guard let stored=try persistence.read(),stored==data else {throw SidecarStorageError(committed:true)}
        state=next
    }
}
