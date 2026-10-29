import CoreAudio
import XCTest

final class RecordingCorePolicyTests: XCTestCase {
    func testWirelessOutputsUseIndependentMicrophoneCapture() {
        XCTAssertTrue(
            RecordingInputRoutePolicy.requiresIndependentCapture(
                outputTransportType: kAudioDeviceTransportTypeBluetooth)
        )
        XCTAssertTrue(
            RecordingInputRoutePolicy.requiresIndependentCapture(
                outputTransportType: kAudioDeviceTransportTypeBluetoothLE)
        )
        XCTAssertTrue(
            RecordingInputRoutePolicy.requiresIndependentCapture(
                outputTransportType: kAudioDeviceTransportTypeAirPlay)
        )
    }

    func testInputThatIsNotSystemDefaultAlwaysUsesIndependentCapture() {
        // 手动选择或替代的麦克风不是系统默认输入，不论输出是什么设备都独立采集，
        // 应用不再通过修改系统默认输入来让 AVAudioEngine 采到它。
        for transport in [nil, kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeBluetooth] as [UInt32?] {
            XCTAssertTrue(
                RecordingInputRoutePolicy.requiresIndependentCapture(
                    outputTransportType: transport,
                    inputFollowsSystemDefault: false
                )
            )
        }
    }

    func testSystemDefaultInputUsesEngineUnlessOutputIsWireless() {
        XCTAssertFalse(
            RecordingInputRoutePolicy.requiresIndependentCapture(
                outputTransportType: kAudioDeviceTransportTypeBuiltIn,
                inputFollowsSystemDefault: true
            )
        )
        XCTAssertFalse(
            RecordingInputRoutePolicy.requiresIndependentCapture(
                outputTransportType: nil,
                inputFollowsSystemDefault: true
            )
        )
        XCTAssertTrue(
            RecordingInputRoutePolicy.requiresIndependentCapture(
                outputTransportType: kAudioDeviceTransportTypeBluetooth,
                inputFollowsSystemDefault: true
            )
        )
    }

    func testWiredOrUnknownOutputsKeepStandardMicrophoneCapture() {
        XCTAssertFalse(
            RecordingInputRoutePolicy.requiresIndependentCapture(
                outputTransportType: kAudioDeviceTransportTypeUSB)
        )
        XCTAssertFalse(
            RecordingInputRoutePolicy.requiresIndependentCapture(outputTransportType: nil)
        )
    }

    func testSystemAudioOnlyDoesNotRequireMicrophonePermission() {
        XCTAssertFalse(
            RecordingPermissionPolicy.requiresMicrophonePermission(isSystemAudioOnly: true)
        )
        XCTAssertTrue(
            RecordingPermissionPolicy.requiresMicrophonePermission(isSystemAudioOnly: false)
        )
    }

    func testRecoveryStateClearsOnlyAfterEveryFinalizationGatePasses() {
        XCTAssertTrue(
            RecordingFinalizationPolicy.shouldClearRecoveryState(
                writerCompleted: true,
                mediaValidationSucceeded: true,
                finalFileExists: true
            )
        )
    }

    func testRecoveryStateIsKeptWhenWriterOrFileValidationFails() {
        XCTAssertFalse(
            RecordingFinalizationPolicy.shouldClearRecoveryState(
                writerCompleted: false,
                mediaValidationSucceeded: true,
                finalFileExists: true
            )
        )
        XCTAssertFalse(
            RecordingFinalizationPolicy.shouldClearRecoveryState(
                writerCompleted: true,
                mediaValidationSucceeded: false,
                finalFileExists: true
            )
        )
        XCTAssertFalse(
            RecordingFinalizationPolicy.shouldClearRecoveryState(
                writerCompleted: true,
                mediaValidationSucceeded: true,
                finalFileExists: false
            )
        )
    }

    func testMP3SourceIsRemovedOnlyAfterEncoderAndFinalMediaValidationSucceed() {
        XCTAssertTrue(
            RecordingFinalizationPolicy.shouldRemoveSourceAfterMP3Finalization(
                encoderSucceeded: true,
                mediaValidationSucceeded: true,
                finalFileExists: true
            )
        )
    }

    func testMP3SourceIsKeptWhenAnyFinalizationGateFails() {
        XCTAssertFalse(
            RecordingFinalizationPolicy.shouldRemoveSourceAfterMP3Finalization(
                encoderSucceeded: false,
                mediaValidationSucceeded: true,
                finalFileExists: true
            )
        )
        XCTAssertFalse(
            RecordingFinalizationPolicy.shouldRemoveSourceAfterMP3Finalization(
                encoderSucceeded: true,
                mediaValidationSucceeded: false,
                finalFileExists: true
            )
        )
        XCTAssertFalse(
            RecordingFinalizationPolicy.shouldRemoveSourceAfterMP3Finalization(
                encoderSucceeded: true,
                mediaValidationSucceeded: true,
                finalFileExists: false
            )
        )
    }

    func testInterruptedRecoveryOnlyMutatesMatchingIdleMarker() {
        XCTAssertTrue(
            RecordingFinalizationPolicy.canApplyInterruptedRecovery(
                expectedPath: "/tmp/old.m4a",
                recordingStateIsIdle: true,
                markerIsActive: true,
                currentMarkerPath: "/tmp/old.m4a"
            )
        )
        XCTAssertFalse(
            RecordingFinalizationPolicy.canApplyInterruptedRecovery(
                expectedPath: "/tmp/old.m4a",
                recordingStateIsIdle: true,
                markerIsActive: true,
                currentMarkerPath: "/tmp/new.m4a"
            )
        )
        XCTAssertFalse(
            RecordingFinalizationPolicy.canApplyInterruptedRecovery(
                expectedPath: "/tmp/old.m4a",
                recordingStateIsIdle: false,
                markerIsActive: true,
                currentMarkerPath: "/tmp/old.m4a"
            )
        )
    }

    func testStartupFinalizesAfterBenignConfigurationNotifications() {
        XCTAssertEqual(
            RecordingStartupStabilityPolicy.action(
                engineIsRunning: true,
                inputConfigurationIsStable: true,
                hasObservedAudioFrames: true,
                minimumObservationReached: true,
                deadlineReached: false
            ),
            .finalize
        )
    }

    func testStartupWaitsForInitialFramesWithoutRebuildingStableEngine() {
        XCTAssertEqual(
            RecordingStartupStabilityPolicy.action(
                engineIsRunning: true,
                inputConfigurationIsStable: true,
                hasObservedAudioFrames: false,
                minimumObservationReached: true,
                deadlineReached: false
            ),
            .wait
        )
    }

    func testStartupRebuildsUnstableConfigurationBeforeDeadline() {
        XCTAssertEqual(
            RecordingStartupStabilityPolicy.action(
                engineIsRunning: false,
                inputConfigurationIsStable: false,
                hasObservedAudioFrames: false,
                minimumObservationReached: true,
                deadlineReached: false
            ),
            .rebuild
        )
    }

    func testStartupFailsOnlyWhenUnstableAtDeadline() {
        XCTAssertEqual(
            RecordingStartupStabilityPolicy.action(
                engineIsRunning: true,
                inputConfigurationIsStable: true,
                hasObservedAudioFrames: false,
                minimumObservationReached: true,
                deadlineReached: true
            ),
            .fail
        )
        XCTAssertEqual(
            RecordingStartupStabilityPolicy.action(
                engineIsRunning: false,
                inputConfigurationIsStable: false,
                hasObservedAudioFrames: false,
                minimumObservationReached: true,
                deadlineReached: true
            ),
            .fail
        )
    }

    func testStableStartupWinsEvenAtDeadlineBoundary() {
        XCTAssertEqual(
            RecordingStartupStabilityPolicy.action(
                engineIsRunning: true,
                inputConfigurationIsStable: true,
                hasObservedAudioFrames: true,
                minimumObservationReached: true,
                deadlineReached: true
            ),
            .finalize
        )
    }

    func testStableStartupWaitsUntilMinimumObservationWindowCompletes() {
        XCTAssertEqual(
            RecordingStartupStabilityPolicy.action(
                engineIsRunning: true,
                inputConfigurationIsStable: true,
                hasObservedAudioFrames: true,
                minimumObservationReached: false,
                deadlineReached: false
            ),
            .wait
        )
    }

    func testStartupInputDeviceMustRemainResolvableAndUnchanged() {
        XCTAssertTrue(
            RecordingStartupStabilityPolicy.inputDeviceIsStable(
                activeInputDeviceID: "built-in-microphone",
                currentDefaultInputDeviceID: "built-in-microphone"
            )
        )
        XCTAssertFalse(
            RecordingStartupStabilityPolicy.inputDeviceIsStable(
                activeInputDeviceID: "built-in-microphone",
                currentDefaultInputDeviceID: "external-microphone"
            )
        )
        XCTAssertFalse(
            RecordingStartupStabilityPolicy.inputDeviceIsStable(
                activeInputDeviceID: "built-in-microphone",
                currentDefaultInputDeviceID: nil
            )
        )
    }

    func testInputDeviceCallbackDoesNotInterruptWhenDeviceIsUnchanged() {
        XCTAssertFalse(
            RecordingInputDeviceChangePolicy.shouldInterruptRecording(
                recordingDeviceID: "built-in-microphone",
                currentDefaultInputDeviceID: "built-in-microphone"
            )
        )
    }

    func testInputDeviceCallbackWaitsWhenCoreAudioTemporarilyCannotResolveDefault() {
        XCTAssertFalse(
            RecordingInputDeviceChangePolicy.shouldInterruptRecording(
                recordingDeviceID: "built-in-microphone",
                currentDefaultInputDeviceID: nil
            )
        )
    }

    func testInputDeviceCallbackInterruptsOnlyForConfirmedDifferentDevice() {
        XCTAssertTrue(
            RecordingInputDeviceChangePolicy.shouldInterruptRecording(
                recordingDeviceID: "built-in-microphone",
                currentDefaultInputDeviceID: "external-microphone"
            )
        )
    }

    func testInputDeviceCallbackDoesNotGuessWhenRecordingDeviceIsUnknown() {
        XCTAssertFalse(
            RecordingInputDeviceChangePolicy.shouldInterruptRecording(
                recordingDeviceID: nil,
                currentDefaultInputDeviceID: "external-microphone"
            )
        )
        XCTAssertFalse(
            RecordingInputDeviceChangePolicy.shouldInterruptRecording(
                recordingDeviceID: "default",
                currentDefaultInputDeviceID: "external-microphone"
            )
        )
    }
}
