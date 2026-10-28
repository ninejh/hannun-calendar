import Foundation
import UserNotifications

enum NotificationAuthorization: String, Codable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral
}
struct NotificationPermission: Codable, Equatable, Sendable {
    var authorization: NotificationAuthorization = .notDetermined
    var alertsEnabled: Bool = false
    var effective: Bool { authorization == .authorized && alertsEnabled }
}
struct LocalPanelNotification: Equatable, Sendable {
    var key: String
    var kind: NotificationKind
    var title: String
    var body: String
    var submittedAt: Instant
}

@MainActor
protocol NotificationAdapter: AnyObject {
    func settings() async throws -> NotificationPermission
    /// Only the explicit preference enable path may invoke this alert-only request.
    func requestAlertAuthorization() async throws -> Bool
    /// Immediate submission only; adapters must never schedule future OS triggers.
    func submit(_ notification: LocalPanelNotification) async throws
}

/// Construct only for production. Demo/HANNUN_TESTING inject a fake instead.
/// The center is lazy: merely constructing services does not access OS notification state.
@MainActor
final class SystemNotificationAdapter: NSObject, NotificationAdapter, UNUserNotificationCenterDelegate {
    private var storedCenter: UNUserNotificationCenter?
    private var center: UNUserNotificationCenter {
        if let storedCenter { return storedCenter }
        let value = UNUserNotificationCenter.current()
        value.delegate = self; storedCenter = value
        return value
    }
    func settings() async throws -> NotificationPermission {
        let settings = await center.notificationSettings()
        let authorization: NotificationAuthorization
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        @unknown default: authorization = .denied
        }
        return NotificationPermission(authorization: authorization, alertsEnabled: settings.alertSetting == .enabled)
    }
    func requestAlertAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }
    func submit(_ notification: LocalPanelNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title; content.body = notification.body
        content.sound = nil; content.badge = nil
        try await center.add(UNNotificationRequest(identifier: "hannun.local." + notification.key, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix("hannun.local.") ? [.banner, .list] : [])
    }
}

enum NotificationPreferenceTarget: Hashable, Sendable { case subscription(UUID), focus }
struct NotificationPreferenceResult: Sendable {
    var enabled: Bool
    var authorization: NotificationAuthorization
    var effective: Bool
    var boardRevision: Int
    var reasonCode: String? = nil
}
struct NotificationServiceError: Error, Equatable, Sendable {
    enum Code: String, Sendable {
        case unavailable = "NOTIFICATION_UNAVAILABLE", submissionFailed = "NOTIFICATION_SUBMISSION_FAILED"
        case boardConflict = "BOARD_CONFLICT", invalidRequest = "INVALID_REQUEST"
    }
    var code: Code
}

/// All durable writes are synchronous BoardStore commits on the existing main-actor FIFO.
/// Permission/OS awaits release that FIFO; entity/revision and scheduling eligibility are
/// checked again after awaits. No window visibility or application activation is consulted.
@MainActor
final class NotificationService {
    private let store: BoardStore
    private let clock: any PanelClock
    private let adapter: any NotificationAdapter
    private let strings: NativeStrings
    private var lastPermissionObservation: Instant?
    private var permissionReadsInFlight = 0
    var didCommitPreference: ((String, BoardState, BoardState) -> Void)?
    var writeGate: (@MainActor (@escaping @MainActor () throws -> Void) async throws -> Void)?
    private func write(_ body: @escaping @MainActor () throws -> Void) async throws {
        if let writeGate { try await writeGate(body) } else { try body() }
    }
    private var previous: PanelClockSnapshot?
    private(set) var nextSubscriptionBoundary: Instant?
    private(set) var permission = NotificationPermission()
    private(set) var lastFailure: String?
    private struct PreferenceRequest {
        var target: NotificationPreferenceTarget
        var enabled: Bool
        var task: Task<NotificationPreferenceResult, any Error>
    }
    private var preferenceRequests: [String: PreferenceRequest] = [:]
    private var latestPreferenceRequest: [NotificationPreferenceTarget: String] = [:]
    private var cancelledPreferences = Set<String>()
    private var authorizationRequest: Task<NotificationPermission, any Error>?
    private var consumedFocusCompletions = Set<UUID>()
    private var subscriptionEligibleAfter: [UUID: Instant] = [:]
    private var focusEligibleAfter: Instant?
    private var schedulingEpoch = UUID()

    init(store: BoardStore, clock: any PanelClock, adapter: any NotificationAdapter, strings: NativeStrings = NativeStrings()) {
        self.store = store; self.clock = clock; self.adapter = adapter; self.strings = strings
    }

    @discardableResult
    func refreshPermission() async throws -> NotificationPermission {
        permissionReadsInFlight += 1
        defer { permissionReadsInFlight -= 1 }
        do {
            permission = try await adapter.settings()
            lastPermissionObservation = clock.snapshot.now
            return permission
        }
        catch { lastFailure = NotificationServiceError.Code.unavailable.rawValue; throw NotificationServiceError(code: .unavailable) }
    }

    /// Passive OS observation never holds the writer or starts a permission prompt.
    func observePermission(_ event: PanelClockEvent) async {
        let now = clock.snapshot.now
        guard permissionReadsInFlight == 0,
              event != .tick || lastPermissionObservation.map({ now.date.timeIntervalSince($0.date) >= 60 || now < $0 }) ?? true else { return }
        _ = try? await refreshPermission()
    }

    /// The application calls this in its synchronous submit turn, before any permission task starts.
    func admitPreference(_ target: NotificationPreferenceTarget, requestID: String) { latestPreferenceRequest[target] = requestID }

    func setPreference(_ target: NotificationPreferenceTarget, enabled: Bool, baseRevision: Int, requestID: String,
                       alreadyAdmitted: Bool = false) async throws -> NotificationPreferenceResult {
        guard !requestID.isEmpty else { throw NotificationServiceError(code: .invalidRequest) }
        if let request = preferenceRequests[requestID] {
            guard request.target == target && request.enabled == enabled else { throw NotificationServiceError(code: .invalidRequest) }
            return try await request.task.value
        }
        // Register the request before the first await; retries share this exact result.
        if !alreadyAdmitted { latestPreferenceRequest[target] = requestID }
        let task = Task { try await self.performPreference(target, enabled: enabled, baseRevision: baseRevision, requestID: requestID) }
        preferenceRequests[requestID] = PreferenceRequest(target: target, enabled: enabled, task: task)
        return try await task.value
    }

    /// Bridge API-18 may suppress a still-pending preference write. OS authorization itself
    /// is not undone. Already committed preference compensation belongs to its normal Undo.
    func cancelPendingPreference(requestID: String) { cancelledPreferences.insert(requestID) }

    /// Call after external board commits, including Undo. Replacing a billing schedule or
    /// restoring an enabled preference arms only future boundaries, never a delayed callback.
    func boardDidCommit(previous old: BoardState) {
        let now = clock.snapshot.now
        for subscription in store.state.subscriptions {
            let before = old.subscriptions.first(where: { $0.id == subscription.id })
            if subscription.notify && (before?.notify != true || before?.scheduleID != subscription.scheduleID || before?.nextDate != subscription.nextDate) {
                subscriptionEligibleAfter[subscription.id] = now
            }
        }
        if store.state.settings.focus.notifyOnFinish && !old.settings.focus.notifyOnFinish { focusEligibleAfter = now }
    }

    private func performPreference(_ target: NotificationPreferenceTarget, enabled: Bool, baseRevision: Int, requestID: String) async throws -> NotificationPreferenceResult {
        guard baseRevision == store.state.boardRevision else { throw NotificationServiceError(code: .boardConflict) }
        let initial = try desired(target, in: store.state) // Unknown/unsaved entities must never prompt.
        if cancelledPreferences.contains(requestID) || latestPreferenceRequest[target] != requestID {
            return NotificationPreferenceResult(enabled: initial, authorization: permission.authorization,
                effective: initial && permission.effective, boardRevision: store.state.boardRevision)
        }
        var allowed = enabled
        if enabled {
            let settings = try await refreshPermission()
            if settings.authorization == .notDetermined {
                if let existing = authorizationRequest { permission = try await existing.value }
                else {
                    let task = Task {
                        do {
                            _ = try await self.adapter.requestAlertAuthorization()
                            return try await self.adapter.settings()
                        } catch { throw NotificationServiceError(code: .unavailable) }
                    }
                    authorizationRequest = task
                    do { permission = try await task.value; authorizationRequest = nil }
                    catch { authorizationRequest = nil; lastFailure = NotificationServiceError.Code.unavailable.rawValue; throw error }
                }
            }
            allowed = permission.authorization == .authorized || permission.authorization == .provisional || permission.authorization == .ephemeral
        }
        let permitted = allowed
        var result: NotificationPreferenceResult?
        try await write { [self] in
        // Do not overwrite intervening edits or resurrect an item deleted during a prompt.
        guard baseRevision == store.state.boardRevision else { throw NotificationServiceError(code: .boardConflict) }
        let current = try desired(target, in: store.state)
        if cancelledPreferences.contains(requestID) || latestPreferenceRequest[target] != requestID {
            result = NotificationPreferenceResult(enabled: current, authorization: permission.authorization,
                effective: current && permission.effective, boardRevision: store.state.boardRevision); return
        }
        let before = store.state
        var next = before
        switch target {
        case let .subscription(id):
            guard let index = next.subscriptions.firstIndex(where: { $0.id == id }) else { throw NotificationServiceError(code: .boardConflict) }
            next.subscriptions[index].notify = permitted
        case .focus: next.settings.focus.notifyOnFinish = permitted
        }
        // BoardStore may publish the candidate and still report a verification failure.
        // Those committed enables must also be restricted to future boundaries.
        defer {
            if store.state != before { boardDidCommit(previous: before) }
            didCommitPreference?(requestID, before, store.state)
        }
        try store.commit(next, baseRevision: baseRevision)
        result = NotificationPreferenceResult(enabled: permitted, authorization: permission.authorization,
            effective: permitted && permission.effective, boardRevision: store.state.boardRevision,
            reasonCode: enabled && !permitted ? "NOTIFICATION_PERMISSION_DENIED" : nil)
        }
        return result!
    }

    /// A native clock scheduler calls this on ticks and explicitly on launch/wake/jumps.
    /// Consuming the boundary before awaiting prevents reentrant callbacks from replaying it.
    @discardableResult
    func reconcile(_ event: PanelClockEvent) async throws -> Int {
        if event == .launch {
            try await write { [self] in
                guard let today = DateOnly(date: clock.snapshot.now.date, timeZone: clock.snapshot.timeZone) else { return }
                let liveSchedules = Set(store.state.subscriptions.map(\.scheduleID))
                var next = store.state
                // D-65 permits only >400 civil-day billing records. Keep any key whose
                // schedule can still recur after a clock rewind, and every uncertain attempt.
                // Startup has no live Undo tombstones; ordinary ticks/edits never prune.
                next.notificationAttempts.removeAll { attempt in
                    attempt.kind == .subscription && attempt.state != .attempted
                        && attempt.dueDate.map { today.ordinal - $0.ordinal > 400 } == true
                        && attempt.scheduleID.map { !liveSchedules.contains($0) } == true
                }
                if next != store.state { try store.commit(next, baseRevision: next.boardRevision) }
            }
        }
        let reading = clock.snapshot
        let boundary = nextSubscriptionBoundary
        let normal = event == .tick && reading.isContinuous(after: previous)
        previous = reading
        if !normal || boundary == nil {
            schedulingEpoch = UUID()
            nextSubscriptionBoundary = nextNine(after: reading)
            return 0
        }
        guard let boundary, reading.now >= boundary else { return 0 }
        nextSubscriptionBoundary = nextNine(after: reading)
        guard reading.now.date.timeIntervalSince(boundary.date) < 60 else { return 0 }
        let candidates = store.state.subscriptions.filter { eligible($0, at: reading) }
        var submissions = 0
        for subscription in candidates {
            guard subscriptionEligibleAfter[subscription.id].map({ $0 < boundary }) ?? true else { continue }
            let attempt = NotificationAttempt(key: subscriptionKey(subscription), kind: .subscription,
                subscriptionID: subscription.id, scheduleID: subscription.scheduleID, dueDate: subscription.nextDate, attemptedAt: reading.now)
            let submitted = await submit(attempt, observation: reading) {
                guard let current = self.store.state.subscriptions.first(where: { $0.id == subscription.id }),
                      current.scheduleID == subscription.scheduleID, current.nextDate == subscription.nextDate,
                      self.subscriptionEligibleAfter[current.id].map({ $0 < boundary }) ?? true else { return false }
                return self.eligible(current, at: self.clock.snapshot)
            }
            if submitted { submissions += 1 }
        }
        return submissions
    }

    /// Consume only FocusReconciliation.finishedSessionID, immediately after its commit.
    /// FocusService deliberately returns nil for every restored/wake/clock-jump completion.
    func submitFocusCompletion(_ sessionID: UUID) async {
        guard consumedFocusCompletions.insert(sessionID).inserted else { return }
        let reading = clock.snapshot
        let attempt = NotificationAttempt(key: sessionID.uuidString.lowercased() + "/finished", kind: .focus,
                                          sessionID: sessionID, attemptedAt: reading.now)
        _ = await submit(attempt, observation: reading) {
            guard self.store.state.settings.focus.notifyOnFinish,
                  self.store.state.focusTimer.status == .completed,
                  let session = self.store.state.focusTimer.session, session.id == sessionID,
                  session.completionKind == .finished, let end = session.completedAt,
                  self.focusEligibleAfter.map({ $0 < end }) ?? true else { return false }
            let elapsed = self.clock.snapshot.now.date.timeIntervalSince(end.date)
            return elapsed >= 0 && elapsed < 60
        }
    }

    private func submit(_ attempt: NotificationAttempt, observation: PanelClockSnapshot, stillEligible: @escaping @MainActor () -> Bool) async -> Bool {
        guard stillEligible(), !store.state.notificationAttempts.contains(where: { $0.key == attempt.key }) else { return false }
        let epoch = schedulingEpoch
        do { _ = try await refreshPermission() }
        catch { return false }
        let now = clock.snapshot
        guard epoch == schedulingEpoch, permission.effective, stillEligible(), now.isContinuous(after: observation),
              now.now.date.timeIntervalSince(observation.now.date) < 60,
              !store.state.notificationAttempts.contains(where: { $0.key == attempt.key }) else { return false }
        var reserved = attempt; reserved.attemptedAt = now.now
        do {
            try await write { [self] in
                let reading = clock.snapshot
                guard epoch == schedulingEpoch, permission.effective, stillEligible(), reading.isContinuous(after: observation),
                      reading.now.date.timeIntervalSince(observation.now.date) < 60,
                      !store.state.notificationAttempts.contains(where: { $0.key == attempt.key }) else { throw NotificationServiceError(code: .unavailable) }
                var next = store.state; next.notificationAttempts.append(reserved)
                try store.commit(next, baseRevision: next.boardRevision)
            }
        } catch {
            lastFailure = (error as? BoardStorageError)?.code.rawValue ?? "STORAGE_WRITE_FAILED"
            return false
        }
        let notification = content(for: reserved)
        let submitted: Bool
        do { try await adapter.submit(notification); submitted = true }
        catch { lastFailure = NotificationServiceError.Code.submissionFailed.rawValue; submitted = false }
        // This status is OS acceptance, never proof of delivery. Failure leaves attempted
        // durable and therefore deduplicated even if the second save also fails or crashes.
        do { try await write { [self] in
            var settled = store.state
            if let index = settled.notificationAttempts.firstIndex(where: { $0.key == attempt.key }) {
                settled.notificationAttempts[index].state = submitted ? .submitted : .failed
                try store.commit(settled, baseRevision: settled.boardRevision)
            }
        } } catch { lastFailure = (error as? BoardStorageError)?.code.rawValue ?? "STORAGE_WRITE_FAILED" }
        return submitted
    }

    private func desired(_ target: NotificationPreferenceTarget, in state: BoardState) throws -> Bool {
        switch target {
        case .focus: return state.settings.focus.notifyOnFinish
        case let .subscription(id):
            guard let value = state.subscriptions.first(where: { $0.id == id }) else { throw NotificationServiceError(code: .boardConflict) }
            return value.notify
        }
    }
    private func subscriptionKey(_ subscription: Subscription) -> String {
        "\(subscription.id.uuidString.lowercased())/\(subscription.scheduleID.uuidString.lowercased())/\(subscription.nextDate)"
    }
    private func eligible(_ subscription: Subscription, at reading: PanelClockSnapshot) -> Bool {
        guard subscription.notify, let today = DateOnly(date: reading.now.date, timeZone: reading.timeZone),
              subscription.nextDate.ordinal - today.ordinal == 1 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = reading.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: reading.now.date)
        return parts.hour == 9 && parts.minute == 0
    }
    private func nextNine(after reading: PanelClockSnapshot) -> Instant? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = reading.timeZone
        return calendar.nextDate(after: reading.now.date, matching: DateComponents(hour: 9, minute: 0, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward).map { Instant(date: $0) }
    }
    private func content(for attempt: NotificationAttempt) -> LocalPanelNotification {
        let language = store.state.settings.language.rawValue
        let title: String, body: String
        switch attempt.kind {
        case .subscription:
            title = strings.text("notification.subscription_title", language: language)
            body = store.state.subscriptions.first(where: { $0.id == attempt.subscriptionID })?.name ?? ""
        case .focus:
            let mode = store.state.focusSessions.first(where: { $0.id == attempt.sessionID })?.mode ?? .focus
            title = strings.text(mode == .focus ? "notification.focus_title" : "notification.break_title", language: language)
            body = ""
        }
        return LocalPanelNotification(key: attempt.key, kind: attempt.kind, title: title, body: body, submittedAt: attempt.attemptedAt)
    }
}
