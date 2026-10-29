import Foundation
import XCTest

final class FileWriteFailureTests: XCTestCase {
    func testLogManagerWritesToTemporaryDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = LogManager(
            logDirectory: directory,
            startupLoggingEnabled: false
        )
        manager.info("temporary log")
        manager.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let logFile = try XCTUnwrap(files.first(where: { $0.pathExtension == "log" }))
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("temporary log"))
    }

    func testLogManagerCatchesSeekFailureAndClosesWithoutRecursion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingLogSink(failingOperations: [.seekToEnd])
        let manager = LogManager(
            logDirectory: directory,
            fileSinkFactory: { _ in sink },
            startupLoggingEnabled: false
        )

        manager.info("seek failure")
        manager.flush()

        XCTAssertEqual(sink.operations, [.seekToEnd, .close])
    }

    func testLogManagerCatchesWriteAndCloseFailuresWithoutRecursion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingLogSink(failingOperations: [.write, .close])
        let manager = LogManager(
            logDirectory: directory,
            fileSinkFactory: { _ in sink },
            startupLoggingEnabled: false
        )

        manager.info("write failure")
        manager.flush()

        XCTAssertEqual(sink.operations, [.seekToEnd, .write, .close])
    }

    func testLogManagerCatchesSynchronizeFailureWithoutRecursion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecordingLogSink(failingOperations: [.synchronize])
        let manager = LogManager(
            logDirectory: directory,
            fileSinkFactory: { _ in sink },
            startupLoggingEnabled: false
        )

        manager.error("sync failure")
        manager.flush()

        XCTAssertEqual(
            sink.operations,
            [.seekToEnd, .write, .synchronize, .close]
        )
    }

    func testMP3WriterReturnsFalseAndClosesAfterWriteFailure() {
        let sink = RecordingMP3Sink(failingOperations: [.write])
        let writer = MP3OutputFileWriter(sink: sink)

        XCTAssertFalse(writer.append(Data([0x01, 0x02])))
        XCTAssertEqual(sink.operations, [.write, .close])
        XCTAssertNotNil(writer.lastError)
    }

    func testMP3WriterRequiresSynchronizeAndCloseBeforeSuccess() {
        let sink = RecordingMP3Sink()
        let writer = MP3OutputFileWriter(sink: sink)

        XCTAssertTrue(writer.append(Data([0x01, 0x02])))
        XCTAssertTrue(writer.finish())
        XCTAssertEqual(sink.operations, [.write, .synchronize, .close])
    }

    func testMP3WriterReturnsFalseWhenSynchronizeFails() {
        let sink = RecordingMP3Sink(failingOperations: [.synchronize])
        let writer = MP3OutputFileWriter(sink: sink)

        XCTAssertTrue(writer.append(Data([0x01])))
        XCTAssertFalse(writer.finish())
        XCTAssertEqual(sink.operations, [.write, .synchronize, .close])
        XCTAssertNotNil(writer.lastError)
    }

    func testMP3WriterRejectsCloseFailureAndDoesNotCloseTwice() {
        let sink = RecordingMP3Sink(failingOperations: [.close])
        let writer = MP3OutputFileWriter(sink: sink)
        XCTAssertTrue(writer.append(Data([0x01])))
        XCTAssertFalse(writer.finish())
        writer.closeAfterFailure()
        XCTAssertEqual(sink.operations, [.write, .synchronize, .close])
    }

    func testMP3WriterCatchesActualReadOnlyFileHandleFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let original = Data("source remains intact".utf8)
        try original.write(to: source)
        let writer = MP3OutputFileWriter(sink: try FileHandle(forReadingFrom: source))
        XCTAssertFalse(writer.append(Data([0x01])))
        XCTAssertNotNil(writer.lastError)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testLoggerRecoversByOpeningNewSinkAfterWriteFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = RecordingLogSink(failingOperations: [.write])
        let healthy = RecordingLogSink()
        var attempts = 0
        let manager = LogManager(logDirectory: directory, fileSinkFactory: { _ in
            attempts += 1
            return attempts == 1 ? failing : healthy
        }, startupLoggingEnabled: false)
        manager.info("failed entry")
        manager.flush()
        manager.info("recovered entry")
        manager.flush()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(healthy.operations, [.seekToEnd, .write, .synchronize])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWriteFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private enum InjectedFileOperation: Hashable {
    case seekToEnd
    case write
    case synchronize
    case close
}

private final class RecordingLogSink: LogFileSink {
    let failingOperations: Set<InjectedFileOperation>
    var operations: [InjectedFileOperation] = []

    init(failingOperations: Set<InjectedFileOperation> = []) {
        self.failingOperations = failingOperations
    }

    func seekToEnd() throws -> UInt64 {
        operations.append(.seekToEnd)
        try failIfNeeded(.seekToEnd)
        return 0
    }

    func write(contentsOf data: Data) throws {
        operations.append(.write)
        try failIfNeeded(.write)
    }

    func synchronize() throws {
        operations.append(.synchronize)
        try failIfNeeded(.synchronize)
    }

    func close() throws {
        operations.append(.close)
        try failIfNeeded(.close)
    }

    private func failIfNeeded(_ operation: InjectedFileOperation) throws {
        guard failingOperations.contains(operation) else { return }
        throw NSError(
            domain: "FileWriteFailureTests",
            code: operation.hashValue,
            userInfo: [NSLocalizedDescriptionKey: "Injected \(operation) failure"]
        )
    }
}

private final class RecordingMP3Sink: MP3OutputSink {
    let failingOperations: Set<InjectedFileOperation>
    var operations: [InjectedFileOperation] = []

    init(failingOperations: Set<InjectedFileOperation> = []) {
        self.failingOperations = failingOperations
    }

    func write(contentsOf data: Data) throws {
        operations.append(.write)
        try failIfNeeded(.write)
    }

    func synchronize() throws {
        operations.append(.synchronize)
        try failIfNeeded(.synchronize)
    }

    func close() throws {
        operations.append(.close)
        try failIfNeeded(.close)
    }

    private func failIfNeeded(_ operation: InjectedFileOperation) throws {
        guard failingOperations.contains(operation) else { return }
        throw NSError(
            domain: "FileWriteFailureTests",
            code: operation.hashValue,
            userInfo: [NSLocalizedDescriptionKey: "Injected \(operation) failure"]
        )
    }
}
