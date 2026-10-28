import Foundation

/// T-022 owns the implementation; T-029 and T-035 use that same instance/type.
/// start/stop are idempotent. System mode registers in RunLoop.common, including midnight,
/// wake and zone reconciliation; manual mode never installs a real clock timer.
/// stop removes runtime timers/observers only. It must not cancel admitted writes/Undo.
@MainActor protocol RuntimeLifecycle: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
}

/// Continuous includes sleep (Undo/network); awake excludes sleep (focus/notifications).
/// System clock and scheduler implementation live exclusively in Application/Runtime.
@MainActor protocol RuntimeClock: AnyObject {
    var snapshot: ClockSnapshot { get }
}

enum RuntimeBuildMode: Sendable { case production, testing }
enum RuntimeMode: Sendable { case production, demoMemory, demoScratch }
enum RuntimeClockMode: Sendable { case system, manual }
enum RuntimeAdapterMode: Sendable { case system, fake }

/// This is the sole construction path; validate it before creating storage or OS/network adapters.
/// --demo, snapshot and self-test map to demoMemory. Normal production/demo uses system time.
/// Fixture decoding/allowlist validation is owned by the test host and must also precede adapters.
struct ValidatedRuntimeConfiguration: Sendable {
    let buildMode: RuntimeBuildMode
    let mode: RuntimeMode
    let clock: RuntimeClockMode
    let adapterMode: RuntimeAdapterMode
    let scratchDirectory: URL?

    private init(buildMode: RuntimeBuildMode, mode: RuntimeMode, clock: RuntimeClockMode,
                 adapterMode: RuntimeAdapterMode, scratchDirectory: URL?) {
        self.buildMode = buildMode
        self.mode = mode
        self.clock = clock
        self.adapterMode = adapterMode
        self.scratchDirectory = scratchDirectory
    }

    /// allowedScratchRoot is the host's trusted <app>/build/e2e-native root, never a fixture field.
    /// The host creates a new 0700 run/scratch directory before calling; this function performs no writes.
    static func validate(mode: RuntimeMode, clock: RuntimeClockMode = .system,
                         scratchDirectory: URL? = nil, allowedScratchRoot: URL? = nil) throws -> Self {
        let buildMode: RuntimeBuildMode
        #if HANNUN_TESTING
        buildMode = .testing
        guard mode != .production else { throw invalidConfiguration() }
        #else
        buildMode = .production
        guard mode != .demoScratch, clock == .system else { throw invalidConfiguration() }
        #endif
        guard mode == .demoScratch || (scratchDirectory == nil && allowedScratchRoot == nil) else {
            throw invalidConfiguration()
        }
        if mode == .demoScratch {
            guard let directory = scratchDirectory, let root = allowedScratchRoot,
                  directory.isFileURL, root.isFileURL,
                  !directory.pathComponents.contains(".."), !root.pathComponents.contains(".."),
                  root.lastPathComponent == "e2e-native", root.deletingLastPathComponent().lastPathComponent == "build",
                  directory.lastPathComponent == "scratch",
                  directory.path.hasPrefix(root.path + "/"),
                  directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path,
                  root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else {
                throw invalidConfiguration()
            }
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let permissions = attributes[.posixPermissions] as? NSNumber,
                      permissions.intValue & 0o777 == 0o700 else { throw invalidConfiguration() }
            } catch { throw invalidConfiguration() }
        }
        return Self(buildMode: buildMode, mode: mode, clock: clock,
                    adapterMode: mode == .production ? .system : .fake, scratchDirectory: scratchDirectory)
    }

    private static func invalidConfiguration() -> AppFailure {
        AppFailure(code: .invalidRequest, field: .configuration, messageKey: "error.invalid_request")
    }
}
