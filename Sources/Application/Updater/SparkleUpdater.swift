import Foundation
import Sparkle

/// A marker is a request to revalidate on a later launch, never permission to install.
@MainActor protocol UpdateDeferralStore: AnyObject {
    func load() -> String?
    func save(_ version: String?)
}

@MainActor final class DefaultsDeferralStore: UpdateDeferralStore {
    private let defaults: UserDefaults
    private let key = "HannunDeferredUpdateInstalledVersion"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> String? { defaults.string(forKey: key) }
    func save(_ version: String?) {
        if let version { defaults.set(version, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        // Best effort: a failed preferences write must not undo session suppression.
        _ = defaults.synchronize()
    }
}

@MainActor final class UpdateDeferral {
    private let store: any UpdateDeferralStore
    private let currentVersion: String
    private var suppressed = false
    private var started = false
    init(store: any UpdateDeferralStore, currentVersion: String) {
        self.store = store
        self.currentVersion = currentVersion
        if let version = store.load(), version != currentVersion { store.save(nil) }
    }
    func takeLaunchCheck(automatic: Bool) -> Bool {
        guard !started else { return false }
        started = true
        return automatic && store.load() == currentVersion
    }
    func allows(check: SPUUpdateCheck) -> Bool {
        !suppressed || check != .updatesInBackground
    }
    func record(choice: SPUUserUpdateChoice, stage: SPUUserUpdateStage) {
        if choice == .dismiss && stage == .notDownloaded {
            suppressed = true
            store.save(currentVersion)
        } else if choice == .skip && stage != .installing {
            store.save(nil)
        }
    }
    func noUpdateFound() { store.save(nil) }
}

/// Sparkle holds its delegate weakly; the updater retains the feed pin and policy.
@MainActor final class SparkleFeedDelegate: NSObject, SPUUpdaterDelegate {
    private let feed: String
    private let deferral: UpdateDeferral
    init(feed: String, deferral: UpdateDeferral? = nil) {
        self.feed = feed
        self.deferral = deferral ?? UpdateDeferral(
            store: DefaultsDeferralStore(),
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }
    func feedURLString(for updater: SPUUpdater) -> String? { feed }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if !deferral.allows(check: updateCheck) {
            throw NSError(domain: "HannunUpdateDeferral", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Update deferred for this session."])
        }
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard !updateItem.isInformationOnlyUpdate else { return }
        deferral.record(choice: choice, stage: state.stage)
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        deferral.noUpdateFound()
    }
    func takeLaunchCheck(automatic: Bool) -> Bool { deferral.takeLaunchCheck(automatic: automatic) }
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
        if feedDelegate.takeLaunchCheck(automatic: controller.updater.automaticallyChecksForUpdates) {
            controller.updater.checkForUpdatesInBackground()
        }
    }
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
#endif
