import Foundation

@MainActor final class BoardViewModel: BoardPresentation {
    private struct Entry {
        var id: UUID
        var command: BoardCommand?
        var affected: [AffectedID]
        var phase: PendingPhase = .running
        var undoSource: UUID? = nil
        var inverse: PreviewInverse? = nil
        var eventInverse: EventPreviewInverse? = nil
        var failure: AppFailure? = nil
        var notesGeneration: Int? = nil
        var fallbackAgenda: (DateOnly, PresentationAnchor?)? = nil
        var feedback: PresentationFeedback? = nil
        var previousPreference: Bool? = nil
        var focusAdmittedAt: Instant? = nil
        // Only native-generated scheduling nonces touched by this projection; never a board cache.
        var projectionSchedules: [UUID: UUID] = [:]
    }
    private struct UndoPreview {
        var source: UUID
        // Undo outlives the source pending entry after ACK; keep its original targets here.
        var affected: [AffectedID]
        var inverse: PreviewInverse?
        var eventInverse: EventPreviewInverse? = nil
        var deadline: Int64
        var requested = false
    }
    static let pendingLimit = 128
    static let recoveryLimit = 32
    private let application: any BoardApplication
    private let scheduler: any PresentationScheduler
    private var stepCandidates: [LayoutStepCandidate] = []
    private var stepCandidateBase: BoardLayout?
    private var base: BoardSnapshot
    private var lastPublishedEnvironment: EnvironmentSnapshot
    private(set) var state: PresentationState
    private var entries: [Entry] = []
    private var recovery: [Entry] = []
    private var handles: [UUID: OperationHandle] = [:]
    private var observers: [(UUID, @MainActor (PresentationChange) -> Void)] = []
    private var observation: ObservationToken?
    private var notesTimer: ObservationToken?
    private var toastTimer: ObservationToken?
    private var undoPreview: UndoPreview?
    private var notesGeneration = 0
    private var disposed = false
    private var seenActions: [UUID] = []
    /// Diagnostic count has no payload exposure; recovery/unknown are deliberately included.
    var retainedIntentCount: Int { entries.count + recovery.count }

    init(application: any BoardApplication, scheduler: any PresentationScheduler = RunLoopPresentationScheduler()) {
        self.application = application; self.scheduler = scheduler; base = application.current
        lastPublishedEnvironment = base.environment
        let today = base.clock.today
        state = PresentationState(snapshot: base, view: PresentationViewState(month: DateOnly(String(format: "%04d-%02d-01", today.year, today.month))!, selectedDay: today))
        observation = application.observe { [weak self] update in self?.receive(update) }
    }
    /// Initial read has no mutation handle; the composition root can await this before UI ready.
    @discardableResult func load(_ range: DisplayRange?) async -> CommandReceipt {
        guard !disposed else { return .failure(AppFailure(code: .staleSession), snapshot: nil) }
        state.activity.loading = true; state.lastError = nil; publish([.activity, .error])
        let receipt = await application.load(range)
        if let snapshot = receipt.snapshot { accept(snapshot) } else { accept(application.current) }
        if case .failure(let failure, _) = receipt { state.lastError = failure }
        state.activity.loading = false; rebuild(); publish([.activity, .board, .calendar, .error])
        return receipt.compact
    }
    func subscribe(_ receive: @escaping @MainActor (PresentationChange) -> Void) -> ObservationToken {
        let id = UUID(); observers.append((id, receive))
        receive(PresentationChange(domains: [.board, .calendar, .clock, .environment, .external, .view, .drafts, .pending, .activity, .toast, .error]))
        return ObservationToken { [weak self] in self?.observers.removeAll { $0.0 == id } }
    }
    func setDraft(_ key: DraftKey, value: DraftValue) {
        guard !disposed else { return }
        state.drafts[key] = value
        if key == .notes { notesGeneration += 1; scheduleNotes() }
        publish([.drafts], affected: key == .notes ? [.notes] : [])
    }
    func clearDraft(_ key: DraftKey) { state.drafts.removeValue(forKey: key); publish([.drafts]) }
    @discardableResult func send(_ intent: UserIntent) -> OperationHandle? {
        guard !disposed else { return nil }
        switch intent {
        case .beginStepPreview(let split, let viewport): beginStepPreview(split, viewport: viewport); return nil
        case .previewStep(let step): previewStep(step); return nil
        case .commitStepPreview: return commitStepPreview()
        case .cancelStepPreview: cancelStepPreview(); return nil
        case .edit(let edit, let undoable, let feedback): return submit(.edit(edit, undoable: undoable), feedback: feedback)
        case .command(let command, let feedback): return submit(command, feedback: feedback)
        case .undo: return requestUndo()
        case .retry(let id):
            guard !entries.contains(where: { $0.id == id }), let i = recovery.firstIndex(where: { $0.id == id }),
                  recovery[i].failure?.committed == .no, (recovery[i].failure?.retryable == true || recovery[i].failure?.code == .boardConflict),
                  let command = recovery[i].command else { return nil }
            let feedback = recovery[i].feedback
            recovery.remove(at: i)
            if case .edit(.notes, _) = command { return startNotes() }
            return submit(command, feedback: feedback)
        case .reconcile(let id): reconcile(id); return nil
        case .selectDay(let day): state.view.selectedDay = day; state.view.followingToday = false
        case .followToday: state.view.selectedDay = base.clock.today; state.view.followingToday = true; state.view.month = month(of: base.clock.today)
        case .movePeriod(let delta):
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            if state.view.mode == .week {
                let offset = delta.multipliedReportingOverflow(by: 7)
                if !offset.overflow, let day = state.view.selectedDay.addingDays(offset.partialValue) {
                    state.view.selectedDay = day; state.view.month = month(of: day)
                }
            } else {
                let value = state.view.month.date(in: calendar.timeZone)
                if let date = calendar.date(byAdding: .month, value: delta, to: value), let day = DateOnly(date: date, timeZone: calendar.timeZone) { state.view.month = month(of: day) }
            }
            state.view.followingToday = false
        case .setMode(let mode): state.view.mode = mode
        case .searchQuery(let query): state.view.query = query
        case .overlayOpen(let route): state.view.overlay = route
        case .revealAgenda(let day, let anchor):
            state.view.selectedDay = day; state.view.followingToday = false; publish([.view])
            return submit(.edit(.panel(.revealAgenda), undoable: true), fallbackAgenda: (day, anchor))
        }
        publish([.view]); return nil
    }
    private func clearStepPreview() {
        state.view.stepPreview = nil; stepCandidates = []; stepCandidateBase = nil
    }
    private func beginStepPreview(_ split: LayoutSplit, viewport: LayoutViewport) {
        let previous = state.snapshot.board.layout
        clearStepPreview(); rebuild()
        let layout = state.snapshot.board.layout
        guard let candidates = try? LayoutStepResolver.candidates(layout: layout, split: split, viewport: viewport) else {
            state.lastError = AppFailure(code: .validationFailed); publish([.board, .view, .error]); return
        }
        stepCandidates = candidates; stepCandidateBase = layout
        state.view.stepPreview = LayoutStepPreview(split: split, viewport: viewport, startingLayout: layout, step: layout.steps[split], layout: layout)
        publish(previous == layout ? [.view] : [.board, .view])
    }
    private func previewStep(_ step: PanelSizeStep) {
        guard var preview = state.view.stepPreview, preview.step != step,
              let candidate = stepCandidates.first(where: { $0.step == step }) else { return }
        preview.step = step; preview.layout = candidate.layout
        state.view.stepPreview = preview; state.snapshot.board.layout = candidate.layout
        publish([.board, .view], affected: Set(SlotID.allCases.map { .slot($0) }))
    }
    private func commitStepPreview() -> OperationHandle? {
        guard let preview = state.view.stepPreview else { return nil }
        clearStepPreview(); rebuild()
        return submit(.edit(.layout(.setStep(preview.split, preview.step, viewport: preview.viewport)), undoable: false), didEndStepPreview: true)
    }
    private func cancelStepPreview() {
        guard state.view.stepPreview != nil else { return }
        let previous = state.snapshot.board.layout
        clearStepPreview(); rebuild()
        publish(previous == state.snapshot.board.layout ? [.view] : [.board, .view])
    }
    private func rebaseStepPreview() {
        guard var preview = state.view.stepPreview else { return }
        let current = state.snapshot.board.layout
        guard current.slots == preview.startingLayout.slots, current.hiddenSlots == preview.startingLayout.hiddenSlots else {
            clearStepPreview(); return
        }
        if stepCandidateBase != current {
            guard let candidates = try? LayoutStepResolver.candidates(layout: current, split: preview.split, viewport: preview.viewport) else {
                clearStepPreview(); return
            }
            stepCandidates = candidates; stepCandidateBase = current
        }
        guard let candidate = stepCandidates.first(where: { $0.step == preview.step }) else { clearStepPreview(); return }
        preview.layout = candidate.layout; state.view.stepPreview = preview; state.snapshot.board.layout = candidate.layout
    }
    private func month(of day: DateOnly) -> DateOnly { DateOnly(String(format: "%04d-%02d-01", day.year, day.month))! }
    private func submit(_ originalCommand: BoardCommand, feedback explicitFeedback: PresentationFeedback? = nil, fallbackAgenda: (DateOnly, PresentationAnchor?)? = nil, notesGeneration: Int? = nil, didEndStepPreview: Bool = false) -> OperationHandle? {
        var endedStepPreview = didEndStepPreview
        var command = originalCommand
        if case .edit(let edit, _) = command, BoardPreview.resizesLayout(edit) {
            if state.view.stepPreview != nil { clearStepPreview(); rebuild(); endedStepPreview = true }
            let unchanged: Bool
            switch edit {
            case .layout(.setStep(let split, let step, let viewport)):
                unchanged = (try? LayoutStepResolver.resolve(layout: state.snapshot.board.layout, split: split, step: step, viewport: viewport)) == state.snapshot.board.layout
            case .layout(.reset):
                var restored = state.snapshot.board.layout; restored.resetSizes(); unchanged = restored == state.snapshot.board.layout
            default: unchanged = false
            }
            if unchanged { if endedStepPreview { publish([.board, .view]) }; return nil }
            command = .edit(edit, undoable: false)
        }
        guard entries.count < Self.pendingLimit else {
            state.lastError = AppFailure(code: .busyRetry, messageKey: "error.busy_retry", retryable: true)
            publish(endedStepPreview ? [.board, .view, .error] : [.error]); return nil
        }
        let id = UUID(), context = OperationContext(id: id, sessionID: base.sessionID, baseRevision: base.boardRevision)
        let edit: BoardEdit?; let undoable: Bool
        if case .edit(let value, let undo) = command { edit = value; undoable = undo }
        else {
            edit = nil
            switch command { case .saveEvent(.metadataOnly): undoable = false; case .saveEvent, .notification: undoable = true; default: undoable = false }
        }
        let affected: [AffectedID]
        if let edit { affected = BoardPreview.affected(edit) }
        else {
            switch command {
            case .saveEvent(.calendarEdit(let identity, _, _, _)), .saveEvent(.metadataOnly(let identity, _)): affected = [.event(identity.id)]
            case .saveEvent(.calendarCreate): affected = [.event("pending:" + id.uuidString.lowercased())]
            case .notification(.subscription(let id), _): affected = [.subscription(id)]
            case .notification(.focus, _), .setLogin, .focus: affected = [.settings]
            default: affected = []
            }
        }
        let feedback = explicitFeedback ?? defaultFeedback(command)
        var previousPreference: Bool?
        if case .notification(let target, _) = command {
            switch target { case .focus: previousPreference = state.snapshot.board.settings.focus.notifyOnFinish
            case .subscription(let id): previousPreference = state.snapshot.board.subscriptions.first { $0.id == id }?.notify }
        }
        var projected = state.snapshot
        apply(command, operationID: id, to: &projected)
        let projectionSchedules = Dictionary(uniqueKeysWithValues: projected.board.subscriptions.compactMap { value -> (UUID, UUID)? in
            state.snapshot.board.subscriptions.first(where: { $0.id == value.id })?.scheduleID == value.scheduleID ? nil : (value.id, value.scheduleID)
        })
        if undoable {
            let deadline = base.clock.continuousMilliseconds.addingReportingOverflow(8000)
            var eventInverse: EventPreviewInverse?
            if case .saveEvent(let input) = command { eventInverse = EventPreviewInverse(input: input, operationID: id, before: state.snapshot.calendar, after: projected.calendar) }
            undoPreview = UndoPreview(source: id, affected: affected, inverse: PreviewInverse(before: state.snapshot.board, after: projected.board), eventInverse: eventInverse, deadline: deadline.overflow ? Int64.max : deadline.partialValue)
            state.toast = PresentationToast(source: id, messageKey: feedback.messageKey, values: feedback.values, continuousDeadlineMilliseconds: undoPreview!.deadline, undoable: true)
            toastTimer?.cancel(); toastTimer = scheduler.schedule(after: 8) { [weak self] in self?.expireToast(force: true) }
        }
        let focusAdmittedAt: Instant?
        if case .focus = command { focusAdmittedAt = base.clock.now } else { focusAdmittedAt = nil }
        entries.append(Entry(id: id, command: command, affected: affected, notesGeneration: notesGeneration, fallbackAgenda: fallbackAgenda, feedback: feedback, previousPreference: previousPreference, focusAdmittedAt: focusAdmittedAt, projectionSchedules: projectionSchedules))
        state.lastError = nil; rebuild()
        // Application ledger admission occurs in this same turn, before any await.
        let handle = application.submit(command, context: context); handles[id] = handle
        watch(handle)
        var domains: Set<PresentationDomain> = [.board, .pending, .activity, .toast, .error]
        if endedStepPreview { domains.insert(.view) }
        publish(domains, affected: Set(affected)); return handle
    }
    private func watch(_ handle: OperationHandle) {
        Task { @MainActor [weak self] in
            let receipt = await handle.settled.value
            self?.settle(handle.id, receipt: receipt)
        }
    }
    private func requestUndo() -> OperationHandle? {
        expireToast()
        guard var undo = undoPreview, !undo.requested, undo.deadline > base.clock.continuousMilliseconds else { return nil }
        undo.requested = true; undoPreview = undo; state.toast?.undoable = false
        let context = OperationContext(id: UUID(), sessionID: base.sessionID, baseRevision: base.boardRevision)
        entries.append(Entry(id: context.id, command: nil, affected: undo.affected, undoSource: undo.source, inverse: undo.inverse, eventInverse: undo.eventInverse))
        let handle = application.requestUndo(source: undo.source, context: context); handles[handle.id] = handle
        rebuild(); watch(handle); publish([.board, .pending, .toast]); return handle
    }
    func reconcile(_ id: UUID) {
        switch application.result(of: id, sessionID: base.sessionID) {
        case .success(.completed(let receipt)): settle(id, receipt: receipt)
        case .success(.notFound):
            // Only proven non-admission is safe to offer as a new explicit retry.
            settle(id, receipt: .failure(AppFailure(code: .busyRetry, retryable: true), snapshot: nil))
        case .success(.retired):
            state.lastError = AppFailure(code: .requestRetired, committed: .unknown)
            publish([.error]) // Re-read can update base but cannot prove an EventKit create did not happen.
        case .failure(let error): state.lastError = error; publish([.error])
        case .success(.pending): break
        }
    }
    private func settle(_ id: UUID, receipt: CommandReceipt) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let snapshot = receipt.snapshot { accept(snapshot) }
        else { accept(application.current) }
        var entry = entries[i]
        switch receipt {
        case .failure(let error, _):
            state.lastError = error; entry.failure = error
            if error.committed == .unknown {
                entries[i].phase = .unknown; entries[i].failure = error
                rebuild(); publish([.pending, .error], affected: Set(entry.affected)); return
            }
            if error.committed == .yes, case .edit(let edit, _) = entry.command { BoardPreview.apply(edit, to: &base.board, clock: base.clock, calendar: base.calendar, projectionSchedules: entry.projectionSchedules) }
            if error.committed == .no {
                if undoPreview?.source == id { undoPreview = nil; state.toast = nil }
                if error.retryable || error.code == .boardConflict { recovery.append(entry); if recovery.count > Self.recoveryLimit { recovery.removeFirst() } }
            }
            if let (day, anchor) = entry.fallbackAgenda { state.view.overlay = .agenda(day, anchor) }
        case .success(let result, _):
            if case .edit(.notes(let saved), _) = entry.command,
               entry.notesGeneration == notesGeneration, state.drafts[.notes]?.textValue?.text == saved { state.drafts.removeValue(forKey: .notes) }
            if state.toast?.source == id {
                if case .eventSaved(let saved) = result {
                    state.toast?.messageKey = saved.warning == nil ? (entry.feedback?.messageKey == "toast.event_moving" ? "toast.event_moved" : "toast.event_saved") : "error.partial_eventkit"
                    state.toast?.values["calendar"] = saved.savedEvent.item.calendarTitle
                    undoPreview?.eventInverse?.after = saved.savedEvent
                } else {
                    state.toast?.messageKey = entry.feedback?.messageKey == "toast.event_saving" ? "success.label" : entry.feedback?.messageKey ?? "success.label"
                }
            }
            if case .eventSaved(let saved) = result {
                state.lastError = saved.warning
                for i in entries.indices where entries[i].undoSource == id { entries[i].eventInverse?.after = saved.savedEvent }
            }
            if case .notification(let result) = result, entry.previousPreference == result.enabled, state.toast?.source == id { state.toast = nil; undoPreview = nil }
            if case .undone(let result) = result { state.lastError = result.warning }
        }
        entries.removeAll { $0.id == id }; handles.removeValue(forKey: id)
        if let source = entry.undoSource, undoPreview?.source == source {
            undoPreview = nil
            if state.toast?.source == source { state.toast = nil }
        }
        rebuild(); publish([.board, .calendar, .pending, .activity, .drafts, .toast, .error, .view], affected: Set(entry.affected))
        if entry.affected.contains(.notes), entry.failure == nil, state.drafts[.notes] != nil { scheduleNotes() }
    }
    private func receive(_ update: BoardUpdate) {
        guard !disposed else { return }
        switch update {
        case .snapshot(let snapshot):
            guard accept(snapshot) else { return }; rebuild(); publish([.board, .calendar, .environment, .external])
        case .clock(let clock):
            base.clock = clock; state.snapshot.clock = clock
            if state.view.followingToday, state.view.selectedDay != clock.today { state.view.selectedDay = clock.today; state.view.month = month(of: clock.today); publish([.view]) }
            expireToast(); publish([.clock])
        case .environment(let environment): base.environment = environment; rebuild(); publish([.environment])
        case .external(let external):
            base.external = external
            if let summary = try? PanelMath.reduceSubscriptions(base.board.subscriptions, rates: external.rates.panelRates, metadata: base.panelMetadata, now: base.clock.now) { base.subscriptionSummary = summary }
            rebuild(); publish([.external])
        case .action(.openSettings(let id)):
            guard !seenActions.contains(id) else { return }; seenActions.append(id); if seenActions.count > 32 { seenActions.removeFirst() }
            state.view.overlay = .settings; publish([.view])
        }
    }
    @discardableResult private func accept(_ snapshot: BoardSnapshot) -> Bool {
        guard snapshot.sessionID == base.sessionID, snapshot.sequence >= base.sequence, snapshot.boardRevision >= base.boardRevision else { return false }
        base = snapshot; return true
    }
    private func rebuild() {
        state.snapshot = base
        for entry in entries {
            if entry.undoSource != nil {
                entry.inverse?.apply(to: &state.snapshot.board)
                entry.eventInverse?.apply(to: &state.snapshot.calendar)
                continue
            }
            guard let command = entry.command else { continue }
            if case .focus = command {
                // A delayed handle must not replay a completed transition over a newer native state.
                switch application.result(of: entry.id, sessionID: base.sessionID) {
                case .success(.completed(.failure(let failure, _))) where failure.committed == .unknown: break
                case .success(.completed), .success(.retired): continue
                default: break
                }
            }
            apply(command, operationID: entry.id, focusAdmittedAt: entry.focusAdmittedAt, projectionSchedules: entry.projectionSchedules, to: &state.snapshot)
        }
        rebaseStepPreview()
        // Native resolved values are authoritative. Override only fields changed by pending writes/Undo.
        if state.snapshot.board.settings.appearance != base.board.settings.appearance {
            switch state.snapshot.board.settings.appearance {
            case .light: state.snapshot.environment.resolvedAppearance = .light
            case .dark: state.snapshot.environment.resolvedAppearance = .dark
            case .system: break
            }
        }
        if state.snapshot.board.settings.weekStart != base.board.settings.weekStart {
            switch state.snapshot.board.settings.weekStart {
            case .sunday: state.snapshot.environment.resolvedWeekStart = 1
            case .monday: state.snapshot.environment.resolvedWeekStart = 2
            case .system: break
            }
        }
        if state.snapshot.board.subscriptions != base.board.subscriptions,
           let summary = try? PanelMath.reduceSubscriptions(state.snapshot.board.subscriptions, rates: base.external.rates.panelRates, metadata: base.panelMetadata, now: base.clock.now) {
            state.snapshot.subscriptionSummary = summary
        }
        // Unsaved notes remain a draft and the projection, including during IME composition.
        if let notes = state.drafts[.notes]?.textValue { state.snapshot.board.notes = notes.text }
        state.pending = entries.map { PendingOperation(id: $0.id, kind: $0.undoSource == nil ? "command" : "undo", phase: $0.phase, affected: $0.affected) }
        state.activity.saving = entries.contains { !$0.affected.isEmpty }
        state.activity.refreshing = entries.contains { if case .refresh = $0.command { true } else { false } }
    }
    private func scheduleNotes() {
        notesTimer?.cancel()
        guard state.drafts[.notes]?.textValue?.isComposing == false else { return }
        notesTimer = scheduler.schedule(after: 0.15) { [weak self] in _ = self?.startNotes() }
    }
    private func startNotes() -> OperationHandle? {
        notesTimer?.cancel(); notesTimer = nil
        guard let draft = state.drafts[.notes]?.textValue, !draft.isComposing,
              !entries.contains(where: { $0.affected.contains(.notes) }) else { return nil }
        if draft.text == base.board.notes { state.drafts.removeValue(forKey: .notes); publish([.drafts], affected: [.notes]); return nil }
        recovery.removeAll { $0.affected.contains(.notes) }
        return submit(.edit(.notes(draft.text), undoable: false), notesGeneration: notesGeneration)
    }
    func flushNotes() async -> CommandReceipt {
        notesTimer?.cancel(); notesTimer = nil
        if state.drafts[.notes]?.textValue?.isComposing == true { return .failure(AppFailure(code: .busyRetry, field: .notes, messageKey: "notes.saving", retryable: true), snapshot: nil) }
        while let pending = entries.first(where: { $0.affected.contains(.notes) }) {
            guard pending.phase != .unknown, let handle = handles[pending.id] else { return .failure(AppFailure(code: .commitOutcomeUnknown, committed: .unknown), snapshot: nil) }
            let receipt = await handle.settled.value; settle(handle.id, receipt: receipt)
            if case .failure = receipt { return receipt.compact }
        }
        if let handle = startNotes() {
            let receipt = await handle.settled.value; settle(handle.id, receipt: receipt)
            if case .failure = receipt { return receipt.compact }
            if state.drafts[.notes] != nil { return await flushNotes() }
        }
        // A refused admission is not a durable save, even if the native store itself flushes.
        if state.drafts[.notes] != nil {
            let failure = AppFailure(code: .busyRetry, field: .notes, messageKey: "notes.saving", retryable: true)
            state.lastError = failure; publish([.error], affected: [.notes])
            return .failure(failure, snapshot: nil)
        }
        return await application.flush()
    }
    private func expireToast(force: Bool = false) {
        guard let undo = undoPreview, force || base.clock.continuousMilliseconds >= undo.deadline else { return }
        state.toast = nil
        if !undo.requested { undoPreview = nil }
        toastTimer?.cancel(); toastTimer = nil; publish([.toast])
    }
    private func apply(_ command: BoardCommand, operationID: UUID, focusAdmittedAt: Instant? = nil, projectionSchedules: [UUID: UUID] = [:], to snapshot: inout BoardSnapshot) {
        switch command {
        case .edit(let edit, _): BoardPreview.apply(edit, to: &snapshot.board, clock: snapshot.clock, calendar: snapshot.calendar, projectionSchedules: projectionSchedules)
        case .saveEvent(let input): EventPreview.apply(input, operationID: operationID, to: &snapshot)
        case .focus(let command): FocusPreview.apply(command, operationID: operationID, admittedAt: focusAdmittedAt ?? snapshot.clock.now, to: &snapshot)
        case .notification(let target, let enabled):
            switch target {
            case .focus: snapshot.board.settings.focus.notifyOnFinish = enabled; snapshot.notification.focusDesired = enabled
            case .subscription(let id):
                if let i = snapshot.board.subscriptions.firstIndex(where: { $0.id == id }) { snapshot.board.subscriptions[i].notify = enabled }
                if let i = snapshot.notification.subscriptions.firstIndex(where: { $0.id == id }) { snapshot.notification.subscriptions[i].desired = enabled }
            }
        default: break
        }
    }
    private func defaultFeedback(_ command: BoardCommand) -> PresentationFeedback {
        let key: String
        switch command {
        case .edit(.project(.delete), _): key = "toast.project_deleted"
        case .edit(.countdown(.delete), _): key = "toast.dday_deleted"
        case .edit(.project(.create), _): key = "toast.project_added"
        case .edit(.countdown(.create), _): key = "toast.countdown_added"
        case .edit(.panel(.deleteSubscription), _): key = "toast.sub_deleted"
        case .edit(.panel(.deleteTodo), _): key = "toast.todo_deleted"
        case .edit(.panel(.deleteHabit), _): key = "toast.habit_deleted"
        case .edit(.eventProject, _): key = "toast.project_linked"
        case .edit(.pin(_, let pinned), _): key = pinned ? "toast.pinned" : "toast.unpinned"
        default: key = "toast.event_saving"
        }
        return PresentationFeedback(messageKey: key)
    }
    private func publish(_ domains: Set<PresentationDomain>, affected: Set<AffectedID> = []) {
        var domains = domains
        if state.snapshot.environment != lastPublishedEnvironment {
            domains.insert(.environment); lastPublishedEnvironment = state.snapshot.environment
        }
        let change = PresentationChange(domains: domains, affected: affected)
        for (_, observer) in observers { observer(change) }
    }
    /// Hide/parking must call flushNotes instead. This ends subscriptions without cancelling accepted writes.
    func dispose() {
        guard !disposed else { return }
        if state.view.stepPreview != nil { clearStepPreview(); rebuild() }
        disposed = true
        observation?.cancel(); observation = nil; notesTimer?.cancel(); notesTimer = nil; toastTimer?.cancel(); toastTimer = nil
        observers = []; handles = [:]; entries = []; recovery = []; undoPreview = nil; state.drafts = [:]; state.pending = []
    }
}
