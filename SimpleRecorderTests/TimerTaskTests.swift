import XCTest

final class TimerTaskTests: XCTestCase {
    func testInitializerClampsInvalidTimeAndReminderValues() {
        let task = TimerTask(hour: 99, minute: -10, reminderMinutes: 99)

        XCTAssertEqual(task.hour, 23)
        XCTAssertEqual(task.minute, 0)
        XCTAssertEqual(task.reminderMinutes, 10)
    }

    func testReminderActionTriggersAtLeadTimeButAutoStartDoesNot() {
        let next = Date().addingTimeInterval(120)

        var reminderTask = TimerTask(repeatType: .daily, actionType: .remind, reminderMinutes: 2)
        reminderTask.nextTriggerTime = next

        var autoStartTask = TimerTask(repeatType: .daily, actionType: .autoStart, reminderMinutes: 2)
        autoStartTask.nextTriggerTime = next

        XCTAssertTrue(reminderTask.shouldTriggerReminder(at: Date()))
        XCTAssertFalse(autoStartTask.shouldTriggerReminder(at: Date()))
    }

    func testReminderDoesNotRetriggerInsideSameWindow() {
        let next = Date().addingTimeInterval(120)
        var task = TimerTask(repeatType: .daily, actionType: .remind, reminderMinutes: 2)
        task.nextTriggerTime = next
        task.lastTriggerTime = Date()

        XCTAssertFalse(task.shouldTriggerReminder(at: Date()))
    }

    func testOneShotTaskDisablesAfterTrigger() {
        var task = TimerTask(repeatType: .none, actionType: .autoStart)
        task.nextTriggerTime = Date()

        task.markAsTriggered()

        XCTAssertFalse(task.enabled)
        XCTAssertNil(task.nextTriggerTime)
        XCTAssertNotNil(task.lastTriggerTime)
    }

    func testDailyReminderAdvancesFromScheduledTimeAfterEarlyReminder() throws {
        let originalNext = Date().addingTimeInterval(120)
        let components = Calendar.current.dateComponents([.hour, .minute], from: originalNext)
        let hour = try XCTUnwrap(components.hour)
        let minute = try XCTUnwrap(components.minute)
        var task = TimerTask(hour: hour, minute: minute, repeatType: .daily, actionType: .remind, reminderMinutes: 2)
        task.nextTriggerTime = originalNext

        task.markAsTriggered()

        let advanced = try XCTUnwrap(task.nextTriggerTime)
        XCTAssertGreaterThan(advanced.timeIntervalSince(originalNext), 23 * 60 * 60)
    }

    func testDaysDisplayCompactsCommonSelections() {
        XCTAssertEqual(TimerTask(daysOfWeek: [1, 2, 3, 4, 5]).daysDisplay, "工作日")
        XCTAssertEqual(TimerTask(daysOfWeek: [6, 7]).daysDisplay, "周末")
        XCTAssertEqual(TimerTask(repeatType: .daily).daysDisplay, "每天")
    }

    func testAutoStartConfirmationPolicyWaitsForAsyncStartup() {
        XCTAssertEqual(
            TimerRecordingStartConfirmationPolicy.decision(for: .starting, remainingAttempts: 1),
            .wait
        )
    }

    func testAutoStartConfirmationPolicyConfirmsOnlyAfterRecording() {
        XCTAssertEqual(
            TimerRecordingStartConfirmationPolicy.decision(for: .recording, remainingAttempts: 0),
            .confirmed
        )
        XCTAssertEqual(
            TimerRecordingStartConfirmationPolicy.decision(for: .starting, remainingAttempts: 0),
            .failed
        )
        XCTAssertEqual(
            TimerRecordingStartConfirmationPolicy.decision(for: .idle, remainingAttempts: 60),
            .failed
        )
    }

    func testScheduleValidatorDetectsSameHourMinuteConflict() {
        let existing = TimerTask(hour: 9, minute: 30)
        let tasks = [existing, TimerTask(hour: 10, minute: 30)]

        XCTAssertTrue(
            TimerTaskScheduleValidator.hasTimeConflict(tasks: tasks, hour: 9, minute: 30)
        )
        XCTAssertFalse(
            TimerTaskScheduleValidator.hasTimeConflict(tasks: tasks, hour: 9, minute: 31)
        )
    }

    func testScheduleValidatorExcludesCurrentTaskWhenEditing() {
        let existing = TimerTask(hour: 9, minute: 30)

        XCTAssertFalse(
            TimerTaskScheduleValidator.hasTimeConflict(
                tasks: [existing],
                hour: 9,
                minute: 30,
                excludingTaskID: existing.id
            )
        )
    }

    func testReminderPresentationTimeoutDoesNotExtendPastScheduledTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var task = TimerTask(actionType: .remind, reminderMinutes: 2)
        task.nextTriggerTime = now.addingTimeInterval(30)

        XCTAssertEqual(TimerReminderPresentationPolicy.timeout(for: task, at: now), 30)

        task.nextTriggerTime = now.addingTimeInterval(-1)
        XCTAssertEqual(TimerReminderPresentationPolicy.timeout(for: task, at: now), 0)
    }

    func testEnabledScheduledTaskRequestsContinuousSleepPrevention() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var task = TimerTask(actionType: .autoStart)
        task.nextTriggerTime = now.addingTimeInterval(60 * 60)

        XCTAssertTrue(TimerTaskSleepPreventionPolicy.shouldPreventSleep(tasks: [task]))
    }

    func testDisabledOrUnscheduledTaskDoesNotRequestSleepPrevention() {
        var disabledTask = TimerTask(enabled: false, actionType: .autoStart)
        disabledTask.nextTriggerTime = Date().addingTimeInterval(60)
        var unscheduledTask = TimerTask(enabled: true, actionType: .autoStart)
        unscheduledTask.nextTriggerTime = nil

        XCTAssertFalse(
            TimerTaskSleepPreventionPolicy.shouldPreventSleep(
                tasks: [disabledTask, unscheduledTask]
            )
        )
    }

    func testTaskOccurrenceChangesWhenSameTaskIsRescheduled() throws {
        var task = TimerTask(actionType: .remind)
        task.nextTriggerTime = Date(timeIntervalSince1970: 1_000_000)
        let original = try XCTUnwrap(TimerTaskOccurrence(task: task))

        task.nextTriggerTime = Date(timeIntervalSince1970: 1_000_060)
        let rescheduled = try XCTUnwrap(TimerTaskOccurrence(task: task))

        XCTAssertNotEqual(original, rescheduled)
        XCTAssertEqual(original.taskID, rescheduled.taskID)
    }

    func testApprovedAutomaticRecordingTaskRemainsAuthorizedAfterPersistenceRoundTrip() throws {
        let store = InMemoryTimerTaskAuthorizationStore()
        let controller = TimerTaskAuthorizationController(store: store)
        var task = TimerTask(
            enabled: true,
            daysOfWeek: [1, 3, 5],
            hour: 9,
            minute: 30,
            repeatType: .weekly,
            actionType: .autoStart
        )
        task.nextTriggerTime = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(controller.authorizeUserChange(from: nil, to: task))

        let encoded = try JSONEncoder().encode(task)
        let restored = try JSONDecoder().decode(TimerTask.self, from: encoded)
        XCTAssertTrue(controller.isAuthorizedForAutomaticRecording(restored))
    }

    func testChangingPersistedAutomaticRecordingScheduleInvalidatesAuthorization() {
        let store = InMemoryTimerTaskAuthorizationStore()
        let controller = TimerTaskAuthorizationController(store: store)
        var task = TimerTask(
            hour: 9,
            minute: 30,
            repeatType: .daily,
            actionType: .autoStart
        )
        task.nextTriggerTime = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(controller.authorizeUserChange(from: nil, to: task))

        task.nextTriggerTime = Date(timeIntervalSince1970: 1_000_060)

        XCTAssertFalse(controller.isAuthorizedForAutomaticRecording(task))
    }

    func testChangingPersistedAutomaticRecordingEnabledStateInvalidatesAuthorization() {
        let store = InMemoryTimerTaskAuthorizationStore()
        let controller = TimerTaskAuthorizationController(store: store)
        var task = TimerTask(enabled: false, actionType: .autoStart)
        XCTAssertTrue(controller.authorizeUserChange(from: nil, to: task))

        task.enabled = true
        task.calculateNextTriggerTime()

        XCTAssertFalse(controller.isAuthorizedForAutomaticRecording(task))
    }

    func testLegacyOrRevokedAutomaticRecordingTaskIsNotAuthorized() {
        let store = InMemoryTimerTaskAuthorizationStore()
        let controller = TimerTaskAuthorizationController(store: store)
        let task = TimerTask(actionType: .autoStart)

        XCTAssertFalse(controller.isAuthorizedForAutomaticRecording(task))
        XCTAssertTrue(controller.authorizeUserChange(from: nil, to: task))
        XCTAssertTrue(controller.isAuthorizedForAutomaticRecording(task))
        XCTAssertTrue(controller.revokeAuthorization(for: task.id))
        XCTAssertFalse(controller.isAuthorizedForAutomaticRecording(task))
    }

    func testReminderUserChangesDoNotDependOnAuthorizationStore() {
        let store = InMemoryTimerTaskAuthorizationStore()
        store.shouldFailSet = true
        store.shouldFailRemoval = true
        let controller = TimerTaskAuthorizationController(store: store)
        let original = TimerTask(actionType: .remind)
        var edited = original
        edited.hour = 10

        XCTAssertTrue(controller.authorizeUserChange(from: nil, to: original))
        XCTAssertTrue(controller.authorizeUserChange(from: original, to: edited))
        XCTAssertEqual(store.setCallCount, 0)
        XCTAssertEqual(store.removeCallCount, 0)
    }

    func testAutomaticRecordingToReminderConversionFailsClosedWhenRevocationFails() {
        let store = InMemoryTimerTaskAuthorizationStore()
        let controller = TimerTaskAuthorizationController(store: store)
        let automaticTask = TimerTask(actionType: .autoStart)
        XCTAssertTrue(controller.authorizeUserChange(from: nil, to: automaticTask))

        var reminderTask = automaticTask
        reminderTask.actionType = .remind
        store.shouldFailRemoval = true

        XCTAssertFalse(controller.authorizeUserChange(from: automaticTask, to: reminderTask))
        XCTAssertTrue(controller.isAuthorizedForAutomaticRecording(automaticTask))
        XCTAssertEqual(store.removeCallCount, 1)
    }
}

private final class InMemoryTimerTaskAuthorizationStore: TimerTaskAuthorizationStore {
    private var digests: [UUID: Data] = [:]
    var shouldFailSet = false
    var shouldFailRemoval = false
    private(set) var setCallCount = 0
    private(set) var removeCallCount = 0

    func authorizationDigest(for taskID: UUID) -> Data? {
        digests[taskID]
    }

    func setAuthorizationDigest(_ digest: Data, for taskID: UUID) -> Bool {
        setCallCount += 1
        guard !shouldFailSet else { return false }
        digests[taskID] = digest
        return true
    }

    func removeAuthorization(for taskID: UUID) -> Bool {
        removeCallCount += 1
        guard !shouldFailRemoval else { return false }
        digests.removeValue(forKey: taskID)
        return true
    }
}
