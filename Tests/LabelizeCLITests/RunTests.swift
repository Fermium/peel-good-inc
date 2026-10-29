import Foundation
import XCTest

/// Runs the built `labelize` binary. Only `preview` and `--dry-run`: nothing is ever printed.
/// The app's settings are never read (LABELIZE_DEFAULTS_DOMAIN=none) and output goes to a temp folder.
final class RunTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("labelize-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var binary: URL {
        get throws {
            let dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            let url = dir.appendingPathComponent("labelize")
            guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("labelize isn't built at \(url.path)") }
            return url
        }
    }

    private func run(_ args: [String]) throws -> (code: Int32, out: String, err: String) {
        XCTAssertFalse(args.contains("--print"), "tests never print")
        let p = Process()
        p.executableURL = try binary
        p.arguments = args
        p.currentDirectoryURL = tmp
        var env = ProcessInfo.processInfo.environment
        env["LABELIZE_DEFAULTS_DOMAIN"] = "none"
        env["LABELIZE_SUPPORT_DIR"] = tmp.appendingPathComponent("support").path
        env["NO_COLOR"] = "1"
        env.removeValue(forKey: "LABELIZE_PRINTER")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    private func sampleSVG() throws -> URL {
        let url = tmp.appendingPathComponent("sample.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="288" height="432" viewBox="0 0 288 432">
          <rect width="288" height="432" fill="white"/><rect x="20" y="20" width="248" height="392" fill="none" stroke="black" stroke-width="4"/>
          <text x="40" y="80" font-size="32">SHIP TO</text><rect x="40" y="300" width="200" height="60" fill="black"/>
        </svg>
        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPreviewJSON() throws {
        let svg = try sampleSVG()
        let r = try run(["preview", svg.path, "--json", "-o", tmp.appendingPathComponent("out").path, "--size", "4x6"])
        XCTAssertEqual(r.code, 0, r.err)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(json["command"] as? String, "preview")
        XCTAssertEqual(json["sent"] as? Bool, false)
        let file = try XCTUnwrap((json["files"] as? [[String: Any]])?.first)
        let pdf = try XCTUnwrap(file["pdf"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf))
        let png = try XCTUnwrap((file["pages"] as? [[String: Any]])?.first?["png"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png))
        XCTAssertNil(file["lp"], "preview never builds a print command")
    }

    func testLegacyFormWritesToOut() throws {
        let svg = try sampleSVG()
        let r = try run([svg.path, "--size", "4x6", "--ink", "crisp"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("out/sample.label.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("out/sample-p1.png").path))
    }

    func testDryRunOnFixtures() throws {
        // Fixtures/ isn't checked in (make-fixtures writes it); use whichever are around.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let candidates = [dir.appendingPathComponent("Fixtures"), dir.deletingLastPathComponent().appendingPathComponent("labelize/Fixtures")]
        guard let fixtures = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("no Fixtures folder") }
        var files = try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted().map { fixtures.appendingPathComponent($0).path }
        let order = NSHomeDirectory() + "/Downloads/order-1460-label.pdf"
        if FileManager.default.fileExists(atPath: order) { files.append(order) }

        let r = try run(["print"] + files + ["--dry-run", "--json"])
        if r.code == 3 { throw XCTSkip("no label printer: \(r.err)") }
        XCTAssertEqual(r.code, 0, r.err)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(json["dryRun"] as? Bool, true)
        XCTAssertEqual(json["sent"] as? Bool, false)
        let reports = try XCTUnwrap(json["files"] as? [[String: Any]])
        XCTAssertEqual(reports.count, files.count)
        for report in reports {
            let lp = try XCTUnwrap(report["lp"] as? [String])
            XCTAssertEqual(lp.first, "lp")
            XCTAssertNil(report["job"], "dry run sent nothing")
            XCTAssertFalse((report["pages"] as? [Any] ?? []).isEmpty)
        }
    }

    func testTestLabelAndStepWedgeDryRun() throws {
        for command in ["test-label", "step-wedge"] {
            let r = try run([command, "--dry-run", "--json", "-o", tmp.path])
            if r.code == 3 { throw XCTSkip("no label printer") }
            XCTAssertEqual(r.code, 0, r.err)
            XCTAssertTrue(r.out.contains("\"dryRun\" : true"))
        }
    }

    func testExitCodesAndHints() throws {
        let missing = try run(["preview", tmp.appendingPathComponent("nope.pdf").path])
        XCTAssertEqual(missing.code, 4)
        XCTAssertTrue(missing.err.contains("no file at"))

        let typo = try run(["prnt", "x.pdf"])
        XCTAssertEqual(typo.code, 2)
        XCTAssertTrue(typo.err.contains("Did you mean `labelize print`?"))

        let printer = try run(["print", try sampleSVG().path, "--printer", "No_Such_Printer_42", "--dry-run"])
        XCTAssertEqual(printer.code, 3)

        let help = try run(["help", "print"])
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.out.contains("EXAMPLES"))
        XCTAssertFalse(help.out.contains("\u{1B}["), "NO_COLOR is respected")
    }

    func testCompletionsAndManPage() throws {
        for shell in ["zsh", "bash"] {
            let r = try run(["completions", shell])
            XCTAssertEqual(r.code, 0)
            let file = tmp.appendingPathComponent("c.\(shell)")
            try r.out.write(to: file, atomically: true, encoding: .utf8)
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/\(shell)")
            check.arguments = ["-n", file.path]
            try check.run()
            check.waitUntilExit()
            XCTAssertEqual(check.terminationStatus, 0, "\(shell) -n")
        }
        let man = try run(["man-page", "--release", "9.9"])
        XCTAssertTrue(man.out.contains(".TH LABELIZE 1"))
        XCTAssertTrue(man.out.contains("Peel Good Inc. 9.9"))
    }

    func testHistoryReadsTheSupportFolder() throws {
        let history = tmp.appendingPathComponent("support/History")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data("%PDF-1.4\n".utf8).write(to: history.appendingPathComponent("2026-10-29T20-03-09Z order-1460-label.label.pdf"))
        let r = try run(["history", "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.first?["name"] as? String, "order-1460-label")
        XCTAssertEqual(rows.first?["date"] as? String, "2026-10-29T20:03:09Z")
    }
}
