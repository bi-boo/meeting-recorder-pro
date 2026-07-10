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
}
