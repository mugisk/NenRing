import Foundation
import XCTest
@testable import NenRing

/// A background child can keep the output pipe open after the process the
/// runner started has exited. The runner then gives up waiting for EOF; the
/// reader must stop on its own instead of reading from a closed handle when
/// the late output arrives.
final class ProcessPipeReaderTests: XCTestCase {
    private let lateWriter = ["-c", "(sleep 0.5; echo late; sleep 0.3; echo later) & echo started"]

    func testBoundedRunnerSurvivesOutputAfterGivingUpOnEOF() throws {
        let runner = BoundedProcessRunner(timeout: 5, terminationGracePeriod: 0.1, outputDrainTimeout: 0.2)

        XCTAssertThrowsError(try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: lateWriter)) { error in
            XCTAssertEqual(error as? BoundedProcessError, .timedOut)
        }
        Thread.sleep(forTimeInterval: 1.2)
    }

    func testASPToolRunnerSurvivesOutputAfterGivingUpOnEOF() throws {
        let runner = ASPToolProcessRunner(policy: ASPToolExecutionPolicy(
            timeout: 5, terminationGracePeriod: 0.1, outputDrainTimeout: 0.2))
        let invocation = ASPToolInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: lateWriter,
            environment: [:],
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            outputContract: .standardOutput(snapshotFileName: "late")
        )

        XCTAssertThrowsError(try runner.run(invocation)) { error in
            XCTAssertEqual(error as? ASPToolGenerationError, .timedOut)
        }
        Thread.sleep(forTimeInterval: 1.2)
    }

    func testOutputAtLimitIsCompleteAndOneByteOverIsRejected() throws {
        let runner = BoundedProcessRunner(timeout: 5, maximumStdoutBytes: 4, maximumStderrBytes: 4)
        let shell = URL(fileURLWithPath: "/bin/sh")
        let result = try runner.run(executable: shell, arguments: ["-c", "printf abcd; printf efgh >&2"])
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "abcd")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "efgh")
        for script in ["printf abcde", "printf abcde >&2"] {
            XCTAssertThrowsError(try runner.run(executable: shell, arguments: ["-c", script])) { error in
                XCTAssertEqual(error as? BoundedProcessError, .outputLimitExceeded)
            }
        }
    }

    func testContinuousOversizedOutputStopsPromptly() throws {
        let runner = BoundedProcessRunner(timeout: 10, terminationGracePeriod: 0.2,
                                          maximumStdoutBytes: 1024, maximumStderrBytes: 1024)
        for script in ["exec /usr/bin/yes", "exec /usr/bin/yes >&2"] {
            let start = Date()
            XCTAssertThrowsError(try runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                arguments: ["-c", script])) { error in
                XCTAssertEqual(error as? BoundedProcessError, .outputLimitExceeded)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    func testSmartctlRunnerReportsOutputOverflow() {
        let runner = LocalSmartctlRunner(timeout: 5, maximumStdoutBytes: 1024)
        XCTAssertThrowsError(try runner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [])) { error in
            XCTAssertEqual(error as? SmartctlServiceError, .outputLimitExceeded)
        }
    }

    func testBoundedRunnerStillReturnsCompleteOutput() throws {
        let runner = BoundedProcessRunner(timeout: 5)
        let script = "head -c 200000 /dev/zero | tr '\\\\0' a; echo; echo err >&2; exit 3"

        let result = try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])

        XCTAssertEqual(result.stdout.count, 200_001)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
        XCTAssertEqual(result.terminationStatus, 3)
    }
}
