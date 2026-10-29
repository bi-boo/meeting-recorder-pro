import XCTest

final class RecordingLifecycleTests: XCTestCase {
    func testExitWaitsForBothRecordingsEvenWhenShorterSecondOneFinishesFirst() {
        let finalizer = RecordingOutputFinalizer()
        finalizer.begin() // 第一段长录音正在转码
        finalizer.begin() // 第二段退出时保存
        var didExit = false
        finalizer.wait { didExit = true }
        finalizer.finish() // 第二段先完成
        XCTAssertFalse(didExit)
        XCTAssertTrue(finalizer.isPending)
        finalizer.finish()
        XCTAssertTrue(didExit)
        XCTAssertFalse(finalizer.isPending)
    }

    func testExitRequestedByIdleNotificationWaitsForRegisteredConversion() {
        let finalizer = RecordingOutputFinalizer()
        finalizer.begin()
        var didExit = false
        let center = NotificationCenter()
        let token = center.addObserver(forName: .init("saved"), object: nil, queue: nil) { _ in
            finalizer.wait { didExit = true }
        }
        defer { center.removeObserver(token) }
        center.post(name: .init("saved"), object: nil)
        XCTAssertFalse(didExit)
        finalizer.finish()
        XCTAssertTrue(didExit)
    }

    func testFinalizationWaitersRunOnceAndSeeIdleState() {
        let finalizer = RecordingOutputFinalizer()
        var pending = false
        var calls = 0
        finalizer.onPendingChanged = { pending = $0 }
        finalizer.begin()
        for _ in 0..<2 {
            finalizer.wait {
                XCTAssertFalse(pending)
                calls += 1
            }
        }
        XCTAssertTrue(finalizer.finish())
        XCTAssertFalse(finalizer.finish())
        XCTAssertEqual(calls, 2)
        finalizer.wait { calls += 1 }
        XCTAssertEqual(calls, 3)
    }

    func testNewOutputStartedByStateObserverKeepsExitWaiting() {
        let finalizer = RecordingOutputFinalizer()
        var startOneMore = true
        var didExit = false
        finalizer.onPendingChanged = { pending in
            if !pending && startOneMore {
                startOneMore = false
                finalizer.begin()
            }
        }
        finalizer.begin()
        finalizer.wait { didExit = true }
        finalizer.finish()
        XCTAssertFalse(didExit)
        finalizer.finish()
        XCTAssertTrue(didExit)
    }

    func testIndependentMicrophoneStallDetectedWhileRendererKeepsProducingSilence() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: 0, now: 100)
        XCTAssertNil(monitor.stalledSource(renderedFrames: 48_000, microphoneFrames: 48_000, now: 101))
        XCTAssertNil(monitor.stalledSource(renderedFrames: 384_000, microphoneFrames: 48_000, now: 108.9))
        XCTAssertEqual(monitor.stalledSource(renderedFrames: 432_000, microphoneFrames: 48_000, now: 109), .microphone)
    }

    func testSilentMicrophoneFramesAreHealthyInput() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: 0, now: 0)
        // 检测输入回调是否产帧，不按音量判断；即使所有采样为零也不能误报。
        for second in 1...60 {
            let frames = Int64(second * 48_000)
            XCTAssertNil(monitor.stalledSource(renderedFrames: frames, microphoneFrames: frames, now: Double(second)))
        }
    }

    func testSystemAudioStallDetectedWhileMixerKeepsRenderingSilence() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: nil, systemAudioFrames: 0, now: 100)
        XCTAssertNil(monitor.stalledSource(renderedFrames: 48_000, microphoneFrames: nil, systemAudioFrames: 48_000, now: 101))
        // SCStream 停止回调后，源节点继续填静音，混音帧照常增长
        XCTAssertNil(monitor.stalledSource(renderedFrames: 384_000, microphoneFrames: nil, systemAudioFrames: 48_000, now: 108.9))
        XCTAssertEqual(monitor.stalledSource(renderedFrames: 432_000, microphoneFrames: nil, systemAudioFrames: 48_000, now: 109), .systemAudio)
    }

    func testSilentSystemAudioCallbacksAreHealthy() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: 0, systemAudioFrames: 0, now: 0)
        for second in 1...60 {
            let frames = Int64(second * 48_000)
            XCTAssertNil(monitor.stalledSource(renderedFrames: frames, microphoneFrames: frames, systemAudioFrames: frames, now: Double(second)))
        }
    }

    func testMicrophoneOnlyCaptureIgnoresSystemAudioCounter() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: nil, systemAudioFrames: nil, now: 0)
        XCTAssertNil(monitor.stalledSource(renderedFrames: 480_000, microphoneFrames: nil, systemAudioFrames: nil, now: 20))
    }

    func testAutomaticRestartDelaysGrowThenGiveUp() {
        XCTAssertEqual(RecordingAutomaticRestartPolicy.delay(forAttempt: 1), 2)
        XCTAssertEqual(RecordingAutomaticRestartPolicy.delay(forAttempt: 2), 5)
        XCTAssertEqual(RecordingAutomaticRestartPolicy.delay(forAttempt: 3), 10)
        XCTAssertNil(RecordingAutomaticRestartPolicy.delay(forAttempt: 4))
        XCTAssertNil(RecordingAutomaticRestartPolicy.delay(forAttempt: 0))
    }

    func testStandardCaptureDoesNotRequireIndependentInputCounter() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: nil, now: 0)
        XCTAssertNil(monitor.stalledSource(renderedFrames: 48_000, microphoneFrames: nil, now: 1))
        XCTAssertEqual(monitor.stalledSource(renderedFrames: 48_000, microphoneFrames: nil, now: 9), .renderedAudio)
    }

    func testStartupAndResumeGetFreshGraceWindow() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: 0, now: 0)
        XCTAssertNil(monitor.stalledSource(renderedFrames: 0, microphoneFrames: 0, now: 13.9))
        XCTAssertEqual(monitor.stalledSource(renderedFrames: 0, microphoneFrames: 0, now: 14), .microphone)
        monitor.reset(renderedFrames: 0, microphoneFrames: 0, now: 600)
        XCTAssertNil(monitor.stalledSource(renderedFrames: 0, microphoneFrames: 0, now: 601))
        XCTAssertNil(monitor.stalledSource(renderedFrames: 48_000, microphoneFrames: 48_000, now: 602))
    }

    func testTransientInputGapResetsAfterFramesResume() {
        var monitor = RecordingCaptureProgressMonitor()
        monitor.reset(renderedFrames: 0, microphoneFrames: 0, now: 0)
        XCTAssertNil(monitor.stalledSource(renderedFrames: 48_000, microphoneFrames: 48_000, now: 1))
        XCTAssertNil(monitor.stalledSource(renderedFrames: 96_000, microphoneFrames: 48_000, now: 7))
        XCTAssertNil(monitor.stalledSource(renderedFrames: 144_000, microphoneFrames: 96_000, now: 8))
        XCTAssertNil(monitor.stalledSource(renderedFrames: 192_000, microphoneFrames: 96_000, now: 15.9))
        XCTAssertEqual(monitor.stalledSource(renderedFrames: 240_000, microphoneFrames: 96_000, now: 16), .microphone)
    }
}
