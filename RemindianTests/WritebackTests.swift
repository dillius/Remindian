import XCTest
@testable import Remindian

/// Tests for ObsidianService vault writeback methods.
///
/// These verify the "surgical edit" contract: only the target line is modified,
/// surrounding content is untouched, and line-offset tracking after recurrence
/// insertions keeps subsequent edits pointed at the correct line.
final class WritebackTests: XCTestCase {

    private var vaultURL: URL!
    private var service: ObsidianService!

    override func setUp() {
        super.setUp()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        service = ObsidianService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: vaultURL)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Write a test markdown file into the temp vault. Returns the relative path.
    private func writeFile(_ name: String, _ content: String) throws -> String {
        let url = vaultURL.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "/\(name)"
    }

    private func readLines(_ name: String) throws -> [String] {
        let url = vaultURL.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - Basic Completion

    func testCompletionSimple() throws {
        let path = try writeFile("t.md",
            "- [ ] Alpha\n- [ ] Bravo\n- [ ] Charlie")

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Bravo",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 0, "No recurrence → no insertion")
        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].hasPrefix("- [ ] Alpha"), "Line above untouched")
        XCTAssertTrue(lines[1].hasPrefix("- [x] Bravo"), "Target completed")
        XCTAssertTrue(lines[1].contains("✅ 2026-03-29"), "Completion date appended")
        XCTAssertTrue(lines[2].hasPrefix("- [ ] Charlie"), "Line below untouched")
    }

    func testCompletionWithRecurrenceInsertsLine() throws {
        let path = try writeFile("t.md",
            "- [ ] Above\n- [ ] Recurring 🔁 every week 📅 2026-03-20\n- [ ] Below")

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 1, "Recurrence inserts 1 line")
        let lines = try readLines("t.md")
        XCTAssertEqual(lines.count, 4, "3 original + 1 inserted")
        XCTAssertTrue(lines[0].hasPrefix("- [ ] Above"), "Line above unaffected")
        XCTAssertTrue(lines[1].contains("- [ ]") && lines[1].contains("🔁"),
                       "Recurrence line is uncompleted with recurrence marker")
        XCTAssertTrue(lines[2].contains("- [x]") && lines[2].contains("✅"),
                       "Original task completed with date")
        XCTAssertTrue(lines[3].hasPrefix("- [ ] Below"), "Line below unaffected")
    }

    func testAlreadyCompletedTaskIsSkipped() throws {
        let original = "- [x] Already done ✅ 2026-03-01"
        let path = try writeFile("t.md", original)

        let inserted = try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        XCTAssertEqual(inserted, 0, "No insertion for already-completed task")
        let lines = try readLines("t.md")
        XCTAssertEqual(lines[0], original, "Line unchanged — no double completion")
    }

    // MARK: - Multi-Task Writeback (core regression tests for the offset fix)

    /// Complete a task with recurrence (inserts a line), then complete a task
    /// BELOW it using the correctly adjusted line number.
    func testMultiTaskUpperRecurrenceThenLowerCompletion() throws {
        let path = try writeFile("t.md", [
            "- [ ] First",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            "- [ ] Third",
            "- [ ] Fourth"
        ].joined(separator: "\n"))

        // Complete line 2 (recurrence) → inserts 1 line
        let ins = try service.markTaskComplete(
            filePath: path, lineNumber: 2,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        XCTAssertEqual(ins, 1)

        // "Third" was at original line 3. Insertion at line 2 (≤ 3) → offset +1 → adjusted 4
        try service.markTaskComplete(
            filePath: path, lineNumber: 4,
            originalLine: "- [ ] Third",
            completionDate: makeDate(2026, 3, 30),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].hasPrefix("- [ ] First"), "First untouched")
        XCTAssertTrue(lines[3].contains("- [x] Third") && lines[3].contains("✅ 2026-03-30"),
                       "Third completed at adjusted line")
        XCTAssertTrue(lines[4].hasPrefix("- [ ] Fourth"), "Fourth untouched")
    }

    /// Complete a task with recurrence at the BOTTOM, then complete one ABOVE it.
    /// The insertion below must NOT offset the upper task.
    func testMultiTaskLowerRecurrenceThenUpperCompletion() throws {
        let path = try writeFile("t.md", [
            "- [ ] First",
            "- [ ] Second",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20"
        ].joined(separator: "\n"))

        // Complete line 3 (recurrence, bottom) → inserts 1 line
        let ins = try service.markTaskComplete(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        XCTAssertEqual(ins, 1)

        // "First" at original line 1. Insertion at line 3 (3 > 1) → NO offset
        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] First",
            completionDate: makeDate(2026, 3, 30),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].contains("- [x] First") && lines[0].contains("✅ 2026-03-30"),
                       "Upper task completed without false offset")
        XCTAssertTrue(lines[1].hasPrefix("- [ ] Second"), "Middle task untouched")
    }

    /// REGRESSION: The old cumulative per-file offset would shift a task ABOVE
    /// the insertion point, causing a content mismatch or wrong-line edit.
    func testInsertionDoesNotOffsetTaskAbove() throws {
        let path = try writeFile("t.md", [
            "- [ ] Task at line 1",
            "- [ ] Task at line 2",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            "- [ ] Task at line 4"
        ].joined(separator: "\n"))

        // Complete line 3 (recurrence) → inserts 1 line
        try service.markTaskComplete(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        // Task at original line 1 — NO offset (insertion was at line 3, below)
        // Old bug: cumulative offset would give 1+1=2, hitting "Task at line 2" instead
        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Task at line 1",
            completionDate: makeDate(2026, 3, 30),
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].contains("- [x] Task at line 1"),
                       "Correct task completed despite insertion below")
    }

    /// Two recurrence insertions at different positions, then metadata update on
    /// a task below both. Needs cumulative position-aware offset of +2.
    func testMultipleRecurrenceInsertionsThenMetadataBelow() throws {
        let path = try writeFile("t.md", [
            "- [ ] RecA 🔁 every week 📅 2026-03-20",     // line 1
            "- [ ] Middle",                                  // line 2
            "- [ ] RecB 🔁 every month 📅 2026-03-15",    // line 3
            "- [ ] Spacer",                                  // line 4
            "- [ ] Target 📅 2026-01-01"                     // line 5
        ].joined(separator: "\n"))

        // Complete line 1 (recurrence) → inserts 1 line. Insertions: [1]
        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] RecA 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        // RecB was at original line 3. Insertions at [1], 1 ≤ 3 → offset 1 → adjusted 4
        try service.markTaskComplete(
            filePath: path, lineNumber: 4,
            originalLine: "- [ ] RecB 🔁 every month 📅 2026-03-15",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        // Insertions now: [1, 3]

        // Target at original line 5. Insertions [1, 3]: both ≤ 5 → offset 2 → adjusted 7
        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 7,
            originalLine: "- [ ] Target 📅 2026-01-01",
            changes: changes,
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[6].contains("Target"), "Correct task at adjusted line 7")
        XCTAssertTrue(lines[6].contains("📅 2026-06-15"), "Due date updated")
        XCTAssertFalse(lines[6].contains("2026-01-01"), "Old date removed")
    }

    // MARK: - Content Mismatch Guard

    /// Using an UNADJUSTED line number after a recurrence insertion should trigger
    /// the content-mismatch guard (the line shifted but the caller didn't account for it).
    func testContentMismatchOnStaleLineNumber() throws {
        let path = try writeFile("t.md",
            "- [ ] Recurring 🔁 every week 📅 2026-03-20\n- [ ] Target")

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        // Line 2 now has the completed recurring task, NOT "Target".
        // Using the unadjusted line should fail.
        XCTAssertThrowsError(
            try service.markTaskComplete(
                filePath: path, lineNumber: 2,
                originalLine: "- [ ] Target",
                completionDate: makeDate(2026, 3, 30),
                vaultPath: vaultURL.path
            )
        ) { error in
            guard case ObsidianError.lineContentMismatch = error else {
                XCTFail("Expected lineContentMismatch, got \(error)")
                return
            }
        }

        // Adjusted line 3 should succeed
        try service.markTaskComplete(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Target",
            completionDate: makeDate(2026, 3, 30),
            vaultPath: vaultURL.path
        )
        let lines = try readLines("t.md")
        XCTAssertTrue(lines[2].contains("- [x] Target"), "Correct line with adjusted number")
    }

    /// Demonstrates why SyncEngine skips metadata writeback after completion on the
    /// same task: the line content changed, so originalLine is stale.
    func testMetadataWritebackFailsAfterCompletionOnSameTask() throws {
        let original = "- [ ] Task 📅 2026-01-01"
        let path = try writeFile("t.md", original)

        try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: original,
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )

        // Metadata writeback with the OLD originalLine → content mismatch
        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        XCTAssertThrowsError(
            try service.updateTaskMetadata(
                filePath: path, lineNumber: 1,
                originalLine: original,
                changes: changes,
                vaultPath: vaultURL.path
            )
        ) { error in
            guard case ObsidianError.lineContentMismatch = error else {
                XCTFail("Expected lineContentMismatch, got \(error)")
                return
            }
        }
    }

    // MARK: - Metadata Update

    func testMetadataUpdateDueDate() throws {
        let original = "- [ ] Task 📅 2026-01-01 #work"
        let path = try writeFile("t.md", original)

        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 1,
            originalLine: original,
            changes: changes,
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[0].contains("📅 2026-06-15"), "Due date updated")
        XCTAssertTrue(lines[0].contains("#work"), "Tags preserved")
        XCTAssertFalse(lines[0].contains("2026-01-01"), "Old date removed")
    }

    func testMetadataUpdateAfterRecurrenceInsertion() throws {
        let path = try writeFile("t.md", [
            "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            "- [ ] Target 📅 2026-01-01 🛫 2026-01-15"
        ].joined(separator: "\n"))

        // Complete line 1 (recurrence) → inserts 1 line
        let ins = try service.markTaskComplete(
            filePath: path, lineNumber: 1,
            originalLine: "- [ ] Recurring 🔁 every week 📅 2026-03-20",
            completionDate: makeDate(2026, 3, 29),
            vaultPath: vaultURL.path
        )
        XCTAssertEqual(ins, 1)

        // "Target" was line 2, insertion at line 1 (≤ 2) → offset +1 → adjusted 3
        var changes = ObsidianService.MetadataChanges()
        changes.newDueDate = .some(makeDate(2026, 6, 15))
        changes.newStartDate = .some(makeDate(2026, 6, 1))
        try service.updateTaskMetadata(
            filePath: path, lineNumber: 3,
            originalLine: "- [ ] Target 📅 2026-01-01 🛫 2026-01-15",
            changes: changes,
            vaultPath: vaultURL.path
        )

        let lines = try readLines("t.md")
        XCTAssertTrue(lines[2].contains("Target"), "Correct task at adjusted line")
        XCTAssertTrue(lines[2].contains("📅 2026-06-15"), "Due date updated")
        XCTAssertTrue(lines[2].contains("🛫 2026-06-01"), "Start date updated")
    }

    // MARK: - Position-Aware Offset Formula

    /// Directly validates the formula: offset = insertions.filter { $0 <= line }.count
    func testPositionAwareOffsetFormula() {
        let insertions = [5, 10, 15]

        // Above all insertions → 0
        XCTAssertEqual(insertions.filter { $0 <= 3 }.count, 0)
        // At first insertion → 1
        XCTAssertEqual(insertions.filter { $0 <= 5 }.count, 1)
        // Between first and second → 1
        XCTAssertEqual(insertions.filter { $0 <= 8 }.count, 1)
        // At second insertion → 2
        XCTAssertEqual(insertions.filter { $0 <= 10 }.count, 2)
        // Between second and third → 2
        XCTAssertEqual(insertions.filter { $0 <= 12 }.count, 2)
        // Below all → 3
        XCTAssertEqual(insertions.filter { $0 <= 20 }.count, 3)
        // Empty insertions → always 0
        XCTAssertEqual([Int]().filter { $0 <= 99 }.count, 0)
    }

    // MARK: - Error Cases

    func testLineNumberOutOfRange() throws {
        let path = try writeFile("t.md", "- [ ] Only line")

        XCTAssertThrowsError(
            try service.markTaskComplete(
                filePath: path, lineNumber: 5,
                originalLine: "- [ ] Only line",
                completionDate: makeDate(2026, 3, 29),
                vaultPath: vaultURL.path
            )
        ) { error in
            guard case ObsidianError.lineNumberOutOfRange = error else {
                XCTFail("Expected lineNumberOutOfRange, got \(error)")
                return
            }
        }
    }

    func testContentMismatchOnWrongOriginalLine() throws {
        let path = try writeFile("t.md", "- [ ] Actual content")

        XCTAssertThrowsError(
            try service.markTaskComplete(
                filePath: path, lineNumber: 1,
                originalLine: "- [ ] Wrong content",
                completionDate: makeDate(2026, 3, 29),
                vaultPath: vaultURL.path
            )
        ) { error in
            guard case ObsidianError.lineContentMismatch = error else {
                XCTFail("Expected lineContentMismatch, got \(error)")
                return
            }
        }
    }
}
