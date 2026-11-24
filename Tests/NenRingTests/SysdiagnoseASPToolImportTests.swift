import Foundation
import XCTest
@testable import NenRing

final class SysdiagnoseASPToolImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent("build/.sysdiagnose-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func touch(_ name: String, modified: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testFindsTheNewestFinishedArchive() throws {
        let old = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try touch("sysdiagnose_2026.11.01_10-00-00+0900_macOS_Mac_26B123.tar.gz", modified: old)
        let newest = try touch("sysdiagnose_2026.11.08_02-00-01+0900_macOS_Mac_26B123.tar.gz",
                               modified: old.addingTimeInterval(3_600))
        _ = try touch("other_2026.tar.gz", modified: old.addingTimeInterval(7_200))

        XCTAssertEqual(SysdiagnoseASPToolLocator.latestArchive(in: directory)?.lastPathComponent,
                       newest.lastPathComponent)
        XCTAssertNil(SysdiagnoseASPToolLocator.latestArchive(in: directory, notBefore: old.addingTimeInterval(7_200)))
        XCTAssertFalse(SysdiagnoseASPToolLocator.isInProgress(in: directory))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("IN_PROGRESS_sysdiagnose_2026.11.08.tmp"),
            withIntermediateDirectories: true)
        XCTAssertTrue(SysdiagnoseASPToolLocator.isInProgress(in: directory))
    }

    func testCopiesOnlyTheASPToolLogOutOfAnArchive() throws {
        let stem = "sysdiagnose_2026.11.08_02-00-01+0900_macOS_Mac_26B123"
        let tree = directory.appendingPathComponent("tree")
        let snapshots = tree.appendingPathComponent("\(stem)/ASPSnapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data("===Grown Bad Blocks===\n".utf8).write(to: snapshots.appendingPathComponent("asptool_snapshot.log"))
        try Data("other".utf8).write(to: snapshots.appendingPathComponent("asptool_magazine_stats.log"))
        let archive = directory.appendingPathComponent("\(stem).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", tree.path, stem]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let imports = directory.appendingPathComponent("imports")
        let extracted = try SysdiagnoseASPToolLocator.extractLog(from: archive, into: imports)

        XCTAssertEqual(extracted.lastPathComponent, "\(stem)-asptool_snapshot.log")
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "===Grown Bad Blocks===\n")
        // Nothing else from the archive is left behind; only the log and its source record remain.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path).sorted(),
                       ["\(stem)-asptool_snapshot.log", "\(stem)-asptool_source.json"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: imports.path).contains("asptool_magazine_stats.log"))
        // Importing the same archive again replaces the earlier copy.
        XCTAssertEqual(try SysdiagnoseASPToolLocator.extractLog(from: archive, into: imports), extracted)
        // An expanded folder is accepted as well.
        XCTAssertEqual(SysdiagnoseASPToolLocator.logInDirectory(tree.appendingPathComponent(stem))?.lastPathComponent,
                       "asptool_snapshot.log")
    }

    func testArchiveWithoutTheLogIsReported() throws {
        let tree = directory.appendingPathComponent("tree/sysdiagnose_x")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tree.appendingPathComponent("system_profiler.spx"))
        let archive = directory.appendingPathComponent("sysdiagnose_x.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", directory.appendingPathComponent("tree").path, "sysdiagnose_x"]
        try tar.run()
        tar.waitUntilExit()

        XCTAssertThrowsError(try SysdiagnoseASPToolLocator.extractLog(
            from: archive, into: directory.appendingPathComponent("imports"))) { error in
            XCTAssertEqual(error as? SysdiagnoseASPToolLocator.LocatorError, .logNotFound)
        }
    }

    func testSymbolicLinkIsNotTreatedAsTheLog() throws {
        let snapshots = directory.appendingPathComponent("expanded/ASPSnapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: snapshots.appendingPathComponent("asptool_snapshot.log"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(SysdiagnoseASPToolLocator.logInDirectory(directory.appendingPathComponent("expanded")))
    }

    // MARK: - Extraction limits

    /// A stand-in for tar that records its PID, optionally writes `fillBytes`
    /// into the staging folder (the fourth argument) and then hangs.
    private func hangingTar(fillBytes: Int = 0) throws -> (tar: URL, pidFile: URL) {
        let pidFile = directory.appendingPathComponent("tar.pid")
        let script = directory.appendingPathComponent("hanging-tar.sh")
        var body = "#!/bin/sh\necho $$ > '\(pidFile.path)'\n"
        if fillBytes > 0 {
            body += "/bin/dd if=/dev/zero of=\"$4/fill\" bs=\(fillBytes) count=1 2>/dev/null\n"
        }
        body += "exec /bin/sleep 30\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, pidFile)
    }

    private func assertStopped(pidFile: URL, imports: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)), file: file, line: line)
        XCTAssertEqual(kill(pid, 0), -1, "the tar stand-in is still running", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix(".extract-") }, "staging left: \(left)", file: file, line: line)
    }

    private func archive(logBytes: Int) throws -> URL {
        let stem = "sysdiagnose_2026.11.11_06-00-00+0900_macOS_Mac_26B123"
        let tree = directory.appendingPathComponent("tree")
        let snapshots = tree.appendingPathComponent("\(stem)/ASPSnapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: logBytes).write(to: snapshots.appendingPathComponent("asptool_snapshot.log"))
        let archive = directory.appendingPathComponent("\(stem).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", tree.path, stem]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return archive
    }

    func testExtractionThatRunsTooLongIsStopped() throws {
        let (tar, pidFile) = try hangingTar()
        let imports = directory.appendingPathComponent("imports")
        let started = Date()
        XCTAssertThrowsError(try SysdiagnoseASPToolLocator.extractLog(
            from: directory.appendingPathComponent("x.tar.gz"), into: imports,
            tarExecutable: tar, timeout: 0.5)) { error in
            XCTAssertEqual(error as? SysdiagnoseASPToolLocator.LocatorError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try assertStopped(pidFile: pidFile, imports: imports)
    }

    func testCancellingStopsTheExtraction() throws {
        let (tar, pidFile) = try hangingTar()
        let imports = directory.appendingPathComponent("imports")
        let cancellation = SysdiagnoseASPToolLocator.Cancellation()
        // Cancel once the stand-in is running, so the PID check below is meaningful.
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            Thread.sleep(forTimeInterval: 0.1)
            cancellation.cancel()
        }
        let started = Date()
        XCTAssertThrowsError(try SysdiagnoseASPToolLocator.extractLog(
            from: directory.appendingPathComponent("x.tar.gz"), into: imports,
            tarExecutable: tar, timeout: 20, cancellation: cancellation)) { error in
            XCTAssertEqual(error as? SysdiagnoseASPToolLocator.LocatorError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try assertStopped(pidFile: pidFile, imports: imports)
    }

    func testAlreadyCancelledExtractionDoesNotStartTar() throws {
        let (tar, pidFile) = try hangingTar()
        let cancellation = SysdiagnoseASPToolLocator.Cancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try SysdiagnoseASPToolLocator.extractLog(
            from: directory.appendingPathComponent("x.tar.gz"), into: directory.appendingPathComponent("imports"),
            tarExecutable: tar, cancellation: cancellation)) { error in
            XCTAssertEqual(error as? SysdiagnoseASPToolLocator.LocatorError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testExtractionThatGrowsPastTheLimitIsStopped() throws {
        let (tar, pidFile) = try hangingTar(fillBytes: 64 * 1_024)
        let imports = directory.appendingPathComponent("imports")
        let started = Date()
        XCTAssertThrowsError(try SysdiagnoseASPToolLocator.extractLog(
            from: directory.appendingPathComponent("x.tar.gz"), into: imports,
            tarExecutable: tar, timeout: 20, maximumLogBytes: 4_096)) { error in
            XCTAssertEqual(error as? SysdiagnoseASPToolLocator.LocatorError, .logTooLarge)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try assertStopped(pidFile: pidFile, imports: imports)
    }

    func testLogOverTheLimitIsRejectedAndLogAtTheLimitIsKept() throws {
        let archive = try archive(logBytes: 8_192)
        let imports = directory.appendingPathComponent("imports")
        XCTAssertThrowsError(try SysdiagnoseASPToolLocator.extractLog(
            from: archive, into: imports, maximumLogBytes: 8_191)) { error in
            XCTAssertEqual(error as? SysdiagnoseASPToolLocator.LocatorError, .logTooLarge)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), [])

        let extracted = try SysdiagnoseASPToolLocator.extractLog(from: archive, into: imports, maximumLogBytes: 8_192)
        XCTAssertEqual(try Data(contentsOf: extracted).count, 8_192)
    }

    func testCorruptArchiveReportsTheExitCode() throws {
        let archive = directory.appendingPathComponent("sysdiagnose_broken.tar.gz")
        try Data("not a gzip stream".utf8).write(to: archive)
        let imports = directory.appendingPathComponent("imports")
        XCTAssertThrowsError(try SysdiagnoseASPToolLocator.extractLog(from: archive, into: imports)) { error in
            guard case .extractionFailed = error as? SysdiagnoseASPToolLocator.LocatorError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), [])
    }

    // MARK: - Source identity

    private static let nvmeProfile = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><array><dict><key>_items</key><array><dict>
      <key>_name</key><string>Apple SSD Controller</string>
      <key>_items</key><array><dict>
        <key>_name</key><string>APPLE SSD AP0256Q</string>
        <key>bsd_name</key><string>disk0</string>
        <key>device_model</key><string>APPLE SSD AP0256Q</string>
        <key>device_revision</key><string>591.40.3</string>
      </dict></array>
    </dict>%@</array></dict></array></plist>
    """

    private func profile(extra: String = "") -> Data {
        Data(Self.nvmeProfile.replacingOccurrences(of: "%@", with: extra).utf8)
    }

    func testReadsTheBuildAndTheInternalSSDFirmware() {
        let swVers = "ProductName:\t\tmacOS\nProductVersion:\t\t27.2\nBuildVersion:\t\t26B123\n"
        let macOS = ASPToolLogSourceIdentity.macOS(fromSwVers: swVers)
        XCTAssertEqual(macOS.build, "26B123")
        XCTAssertEqual(macOS.version, "27.2")

        XCTAssertEqual(ASPToolLogSourceIdentity.appleSSD(fromSystemProfiler: profile())?.firmware, "591.40.3")
        // An external NVMe drive is not taken for the internal SSD.
        let external = "<dict><key>_items</key><array><dict><key>device_model</key><string>Samsung SSD 990</string>" +
            "<key>device_revision</key><string>4B2QJXD7</string></dict></array></dict>"
        XCTAssertEqual(ASPToolLogSourceIdentity.appleSSD(fromSystemProfiler: profile(extra: external))?.model,
                       "APPLE SSD AP0256Q")
        // Two different Apple SSDs: the drive is not guessed.
        let second = "<dict><key>_items</key><array><dict><key>device_model</key><string>APPLE SSD AP1024Z</string>" +
            "<key>device_revision</key><string>600.1</string></dict></array></dict>"
        XCTAssertNil(ASPToolLogSourceIdentity.appleSSD(fromSystemProfiler: profile(extra: second)))
        XCTAssertNil(ASPToolLogSourceIdentity.appleSSD(fromSystemProfiler: Data("not a plist".utf8)))
    }

    func testArchiveImportRecordsTheSourceAndTheOutputTime() throws {
        let stem = "sysdiagnose_2026.11.11_10-27-24+0900_macOS_Mac_26B123"
        let tree = directory.appendingPathComponent("tree")
        let root = tree.appendingPathComponent(stem)
        let snapshots = root.appendingPathComponent("ASPSnapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("SystemProfiler"),
                                                withIntermediateDirectories: true)
        let log = snapshots.appendingPathComponent("asptool_snapshot.log")
        try Data("===Grown Bad Blocks===\n".utf8).write(to: log)
        let writtenAt = Date(timeIntervalSince1970: 1_794_360_480)
        try FileManager.default.setAttributes([.modificationDate: writtenAt], ofItemAtPath: log.path)
        try Data("ProductVersion:\t\t27.2\nBuildVersion:\t\t26B123\n".utf8)
            .write(to: root.appendingPathComponent("sw_vers.txt"))
        try profile().write(to: root.appendingPathComponent("SystemProfiler/SPNVMeDataType.spx"))
        let archive = directory.appendingPathComponent("\(stem).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", tree.path, stem]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        // Copying the archive changes its own date, not the dates recorded inside it.
        let copy = directory.appendingPathComponent("copied/\(stem).tar.gz")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: archive, to: copy)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)

        let imports = directory.appendingPathComponent("imports")
        let extracted = try SysdiagnoseASPToolLocator.extractLog(from: copy, into: imports)
        let identity = try XCTUnwrap(SysdiagnoseASPToolLocator.sourceIdentity(forLog: extracted))
        XCTAssertEqual(identity.logWrittenAt, writtenAt)
        XCTAssertEqual(identity.macOSBuild, "26B123")
        XCTAssertEqual(identity.macOSVersion, "27.2")
        XCTAssertEqual(identity.ssdModel, "APPLE SSD AP0256Q")
        XCTAssertEqual(identity.ssdFirmware, "591.40.3")
        // The serial number is not kept.
        XCTAssertFalse(String(decoding: try Data(contentsOf: imports.appendingPathComponent("\(stem)-asptool_source.json")),
                              as: UTF8.self).contains("serial"))

        // Touching the copied log later does not move the recorded output time.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: extracted.path)
        XCTAssertEqual(SysdiagnoseASPToolLocator.sourceIdentity(forLog: extracted)?.logWrittenAt, writtenAt)

        // A log read on its own has no source record.
        let loose = directory.appendingPathComponent("asptool_snapshot.log")
        try FileManager.default.copyItem(at: extracted, to: loose)
        XCTAssertNil(SysdiagnoseASPToolLocator.sourceIdentity(forLog: loose))
        XCTAssertNil(SysdiagnoseASPToolLocator.sourceIdentity(forLog: nil))
    }

    func testRunnerStopHookTerminatesTheChild() throws {
        let runner = BoundedProcessRunner(timeout: 20)
        struct Stop: Error {}
        let started = Date()
        XCTAssertThrowsError(try runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) {
            Date().timeIntervalSince(started) > 0.2 ? Stop() : nil
        }) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTerminalScriptRunsSysdiagnoseWithSudoAndQuotesText() throws {
        let script = SysdiagnoseTerminalLauncher.script(language: "ja")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("if /usr/bin/sudo /usr/bin/sysdiagnose; then"))
        XCTAssertTrue(script.contains("Touch ID"))
        XCTAssertFalse(SysdiagnoseTerminalLauncher.script(language: "en").contains("パスワード"))
        XCTAssertEqual(SysdiagnoseTerminalLauncher.shellQuoted("it's"), #"'it'\''s'"#)

        let url = try SysdiagnoseTerminalLauncher.writeScript(into: directory, language: "en")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        XCTAssertEqual(url.pathExtension, "command")
    }
}
