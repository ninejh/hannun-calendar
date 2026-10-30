import Foundation

/// Pure projection only. Validation, domain arithmetic, persistence and durable inverses stay native.
enum BoardPreview {
    static func apply(_ edit: BoardEdit, to board: inout BoardState, clock: ClockSnapshot, calendar: CalendarSnapshot? = nil, projectionSchedules: [UUID: UUID] = [:]) {
        switch edit {
        case .transaction(let edits): for edit in edits { apply(edit.boardEdit, to: &board, clock: clock, calendar: calendar, projectionSchedules: projectionSchedules) }
        case .notes(let text): board.notes = text
        case .project(let edit):
            switch edit {
            case .create(let input):
                guard !board.projects.contains(where: { $0.id == input.id }) else { return }
                var value = Project(id: input.id, title: input.title, focus: input.focus, nextStep: input.nextStep, status: input.status, colorHex: input.colorHex, progress: input.progress)
                value.targetDay = input.targetDay; board.projects.append(value)
            case .update(let id, let patch):
                guard let i = board.projects.firstIndex(where: { $0.id == id }) else { return }
                patch.title.apply(to: &board.projects[i].title); patch.focus.apply(to: &board.projects[i].focus)
                patch.nextStep.apply(to: &board.projects[i].nextStep); patch.status.apply(to: &board.projects[i].status)
                patch.targetDay.apply(to: &board.projects[i].targetDay); patch.colorHex.apply(to: &board.projects[i].colorHex)
                patch.progress.apply(to: &board.projects[i].progress)
            case .delete(let id):
                board.projects.removeAll { $0.id == id }
                board.eventProjectLinks = board.eventProjectLinks.filter { $0.value.lowercased() != id.uuidString.lowercased() }
            }
        case .countdown(let edit):
            switch edit {
            case .create(let input):
                guard !board.milestones.contains(where: { $0.id == input.id }) else { return }
                var value = Milestone(id: input.id, title: input.title, date: input.day.date(in: TimeZone(secondsFromGMT: 0)!), colorHex: input.colorHex)
                value.day = input.day; board.milestones.append(value)
            case .update(let id, let patch):
                guard let i = board.milestones.firstIndex(where: { $0.id == id }) else { return }
                patch.title.apply(to: &board.milestones[i].title); patch.day.apply(to: &board.milestones[i].day); patch.colorHex.apply(to: &board.milestones[i].colorHex)
            case .delete(let id): board.milestones.removeAll { $0.id == id }
            }
        case .pin(let event, let pinned):
            let key = calendar?.records.first { $0.id == event.id }?.pinKey ?? event.id
            if pinned { board.pinnedEventKeys.insert(key) } else { board.pinnedEventKeys.remove(key) }
        case .eventProject(let event, let project):
            let key = calendar?.records.first { $0.id == event.id }?.pinKey ?? event.id
            board.eventProjectLinks[key] = project?.uuidString.lowercased()
        case .calendarVisibility(let id, let hidden): if hidden { board.hiddenCalendarIDs.insert(id) } else { board.hiddenCalendarIDs.remove(id) }
        case .layout(let edit):
            switch edit {
            case .select(let slot, let panel):
                let old = board.layout.slots[slot.rawValue]
                if let other = board.layout.slots.first(where: { $0.value == panel })?.key { board.layout.slots[other] = old }
                board.layout.slots[slot.rawValue] = panel
            case .setHidden(let slot, let hidden):
                if hidden { board.layout.hiddenSlots.insert(slot.rawValue) }
                else if let restored = try? GridResolver.restore(slot, in: board.layout) { board.layout = restored }
            case .setStep(let split, let step, let viewport):
                if let layout = try? LayoutStepResolver.resolve(layout: board.layout, split: split, step: step, viewport: viewport) {
                    board.layout = layout
                }
            case .place(let item, let rect):
                if let layout = try? GridResolver.place(item, rect: rect, in: board.layout) { board.layout = layout }
            case .dismissMigrationNotice: board.layout.migrationNoticePending = false
            case .setSplit: break // Native rejects legacy ratio writes; they have no optimistic projection.
            case .reset: board.layout.resetSizes()
            }
        case .settings(let p):
            p.desktopMode.apply(to: &board.settings.desktopMode); p.fontScale.apply(to: &board.settings.fontScale)
            p.opacity.apply(to: &board.settings.opacity); p.importantOnly.apply(to: &board.settings.importantOnly)
            p.showCompletedProjects.apply(to: &board.settings.showCompletedProjects); p.appearance.apply(to: &board.settings.appearance)
            p.compact.apply(to: &board.settings.compact); p.language.apply(to: &board.settings.language)
            p.weekStart.apply(to: &board.settings.weekStart); p.networkEnabled.apply(to: &board.settings.networkEnabled)
            p.ratesEnabled.apply(to: &board.settings.ratesEnabled); p.weather.apply(to: &board.settings.weather)
            p.todosCompletedCollapsed.apply(to: &board.settings.todosCompletedCollapsed); p.focus.apply(to: &board.settings.focus)
        case .panel(let intent):
            let cities: Set<String>
            if case .addCity(let city) = intent { cities = [city] } else { cities = [] }
            if let mutation = try? PanelDomain.apply(intent, to: board, now: clock.now, today: clock.today, validCityIDs: cities) {
                var next = mutation.state
                for i in next.subscriptions.indices {
                    let value = next.subscriptions[i]
                    if let nonce = projectionSchedules[value.id],
                       board.subscriptions.first(where: { $0.id == value.id })?.scheduleID != value.scheduleID {
                        next.subscriptions[i].scheduleID = nonce
                    }
                }
                board = next
            }
        }
    }
    static func resizesLayout(_ edit: BoardEdit) -> Bool {
        switch edit {
        case .layout(.setStep), .layout(.reset): true
        case .transaction(let edits): edits.contains { resizesLayout($0.boardEdit) }
        default: false
        }
    }
    static func affected(_ edit: BoardEdit) -> [AffectedID] {
        switch edit {
        case .notes: [.notes]
        case .settings: [.settings]
        case .project(let edit): switch edit { case .create(let v): [.project(v.id)]; case .update(let id, _), .delete(let id): [.project(id)] }
        case .countdown(let edit): switch edit { case .create(let v): [.countdown(v.id)]; case .update(let id, _), .delete(let id): [.countdown(id)] }
        case .pin(let id, _), .eventProject(let id, _): [.event(id.id)]
        case .calendarVisibility(let id, _): [.calendar(id)]
        case .layout(let edit): switch edit { case .select(let slot, _), .setHidden(let slot, _): [.slot(slot)]; default: SlotID.allCases.map { .slot($0) } }
        case .transaction(let edits): edits.flatMap { affected($0.boardEdit) }
        case .panel(let p):
            switch p {
            case .createSubscription(let v): [.subscription(v.id)]
            case .updateSubscription(let id, _), .deleteSubscription(let id): [.subscription(id)]
            case .createTodo(let id, _), .updateTodo(let id, _), .deleteTodo(let id): [.todo(id)]
            case .createHabit(let id, _), .updateHabit(let id, _), .setHabitToday(let id, _, _), .deleteHabit(let id): [.habit(id)]
            case .addCity(let id), .deleteCity(let id): [.city(id)]
            case .selectSlot(let slot, _), .setSlotVisible(let slot, _): [.slot(slot)]
            default: SlotID.allCases.map { .slot($0) }
            }
        }
    }
}
extension FieldChange {
    func apply(to value: inout Value) { if case .set(let next) = self { value = next } }
}
extension AtomicBoardEdit {
    var boardEdit: BoardEdit {
        switch self {
        case .notes(let v): .notes(v); case .project(let v): .project(v); case .countdown(let v): .countdown(v)
        case .pin(let id, let v): .pin(id, v); case .eventProject(let id, let v): .eventProject(id, v)
        case .calendarVisibility(let id, let v): .calendarVisibility(id: id, isHidden: v)
        case .settings(let v): .settings(v); case .layout(let v): .layout(v); case .panel(let v): .panel(v)
        }
    }
}
