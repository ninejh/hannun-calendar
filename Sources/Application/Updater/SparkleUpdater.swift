import Foundation
import Sparkle

/// Sparkle holds its delegate weakly; the updater retains this immutable feed pin.
@MainActor final class SparkleFeedDelegate: NSObject, SPUUpdaterDelegate {
    private let feed: String
    init(feed: String) { self.feed = feed }
    func feedURLString(for updater: SPUUpdater) -> String? { feed }
}

@MainActor protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    func start()
    func checkForUpdates()
}

@MainActor enum AppUpdaterFactory {
    static func make(configuration: ValidatedRuntimeConfiguration) -> (any AppUpdating)? {
#if HANNUN_TESTING
        return nil
#else
        guard configuration.mode == .production,
              let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
              feed == "https://hannun-calendar.vercel.app/appcast.xml" else { return nil }
        return SparkleUpdater(feed: feed)
#endif
    }
#if HANNUN_TESTING && HANNUN_UPDATER_INTEGRATION_TEST
    /// Explicitly injected only by the separately compiled, signed synthetic fixture.
    /// Both expected values are fixed in that fixture's own signed Info.plist at build time.
    static func makeIsolatedIntegration(configuration: ValidatedRuntimeConfiguration) -> (any AppUpdating)? {
        let bundle = Bundle.main
        let prefix = "io.github.ninejh.hannuncalendar.updatertest."
        guard configuration.buildMode == .testing, configuration.mode == .demoScratch,
              configuration.clock == .manual, configuration.adapterMode == .fake,
              let identifier = bundle.bundleIdentifier, identifier.hasPrefix(prefix), identifier.count > prefix.count,
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let expectedFeed = bundle.object(forInfoDictionaryKey: "HannunUpdaterTestFeedURL") as? String,
              feed == expectedFeed, let url = URL(string: feed), url.scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "hannun-calendar.vercel.app", !host.hasSuffix(".hannun-calendar.vercel.app"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let expectedKey = bundle.object(forInfoDictionaryKey: "HannunUpdaterTestPublicEDKey") as? String,
              key == expectedKey, Data(base64Encoded: key)?.count == 32 else { return nil }
        return SparkleUpdater(feed: feed)
    }
#endif
}

#if !HANNUN_TESTING || HANNUN_UPDATER_INTEGRATION_TEST
/// Retain both this object and its standard controller for the application lifetime.
@MainActor private final class SparkleUpdater: AppUpdating {
    private let feedDelegate: SparkleFeedDelegate
    private let controller: SPUStandardUpdaterController
    private var started = false
    init(feed: String) {
        let delegate = SparkleFeedDelegate(feed: feed)
        feedDelegate = delegate
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    }
    var canCheckForUpdates: Bool { started && controller.updater.canCheckForUpdates }
    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
#endif
