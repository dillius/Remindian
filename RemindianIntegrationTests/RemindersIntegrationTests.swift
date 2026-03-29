import XCTest
import EventKit
@testable import Remindian

/// Integration tests for RemindersDestination using a dedicated test list.
///
/// These tests exercise the full EventKit CRUD lifecycle against Apple Reminders.
/// All operations are confined to a list named "Remindian-Tests" which is created
/// once for the class and cleaned between tests.
///
/// Requirements:
/// - macOS Reminders access must be granted to the test host.
/// - An active Reminders account (iCloud or local) must exist.
final class RemindersIntegrationTests: XCTestCase {

    static let testListName = "Remindian-Tests"

    // Shared across all tests to avoid "too many EKEventStore instances" error
    private static let eventStore = EKEventStore()
    private static let destination = RemindersDestination()
    private static var testList: EKCalendar?
    private static var accessGranted = false

    private var config: SyncConfiguration!

    override func setUp() async throws {
        try await super.setUp()

        config = SyncConfiguration()
        config.defaultList = Self.testListName

        // Check authorization without prompting. If Reminders access hasn't been
        // granted yet, skip silently. Grant access once via System Settings or by
        // running the app normally, and integration tests will run automatically.
        if !Self.accessGranted {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            let hasAccess: Bool
            if #available(macOS 14.0, *) {
                hasAccess = status == .fullAccess
            } else {
                hasAccess = status == .authorized
            }
            guard hasAccess else {
                throw XCTSkip("Reminders access not granted — grant via System Settings to enable integration tests")
            }
            Self.accessGranted = true
        }

        // Create the test list once (or find existing)
        if Self.testList == nil {
            let store = Self.eventStore
            Self.testList = store.calendars(for: .reminder).first { $0.title == Self.testListName }
            if Self.testList == nil {
                let calendar = EKCalendar(for: .reminder, eventStore: store)
                calendar.title = Self.testListName
                if let source = store.defaultCalendarForNewReminders()?.source {
                    calendar.source = source
                } else if let local = store.sources.first(where: { $0.sourceType == .local }) {
                    calendar.source = local
                } else {
                    throw XCTSkip("No Reminders source available")
                }
                try store.saveCalendar(calendar, commit: true)
                Self.testList = calendar
            }
        }

        // Clean any leftover reminders before each test
        try await deleteAllRemindersInTestList()
    }

    override func tearDown() async throws {
        try? await deleteAllRemindersInTestList()
        try await super.tearDown()
    }

    // MARK: - Tests

    func testCreateAndFetchTask() async throws {
        let task = SyncTask(
            title: "Integration test task",
            priority: .high,
            dueDate: Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15)),
            tags: ["#test"]
        )

        let id = try await Self.destination.createTask(from: task, inList: Self.testListName, config: config)
        XCTAssertFalse(id.isEmpty, "Should return a non-empty reminder ID")

        guard let reminder = Self.eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            XCTFail("Created reminder not found by ID")
            return
        }

        XCTAssertEqual(reminder.title, "Integration test task")
        XCTAssertEqual(reminder.priority, 1) // high
        XCTAssertFalse(reminder.isCompleted)
        XCTAssertEqual(reminder.calendar.title, Self.testListName)

        let dueComponents = reminder.dueDateComponents
        XCTAssertEqual(dueComponents?.year, 2026)
        XCTAssertEqual(dueComponents?.month, 6)
        XCTAssertEqual(dueComponents?.day, 15)
    }

    func testUpdateTask() async throws {
        let task = SyncTask(title: "Before update", priority: .low)
        let id = try await Self.destination.createTask(from: task, inList: Self.testListName, config: config)

        let updated = SyncTask(title: "After update", priority: .high, dueDate: Date())
        try await Self.destination.updateTask(withId: id, from: updated, config: config)

        guard let reminder = Self.eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            XCTFail("Updated reminder not found")
            return
        }

        XCTAssertEqual(reminder.title, "After update")
        XCTAssertEqual(reminder.priority, 1) // high
        XCTAssertNotNil(reminder.dueDateComponents)
    }

    func testDeleteTask() async throws {
        let task = SyncTask(title: "To be deleted")
        let id = try await Self.destination.createTask(from: task, inList: Self.testListName, config: config)

        XCTAssertNotNil(Self.eventStore.calendarItem(withIdentifier: id))

        try await Self.destination.deleteTask(withId: id)

        // EventKit caches aggressively — reset to see the deletion
        Self.eventStore.reset()
        XCTAssertNil(Self.eventStore.calendarItem(withIdentifier: id), "Reminder should be deleted")
    }

    func testCompleteTask() async throws {
        let task = SyncTask(title: "Complete me")
        let id = try await Self.destination.createTask(from: task, inList: Self.testListName, config: config)

        let completedTask = SyncTask(
            title: "Complete me",
            isCompleted: true,
            completedDate: Date()
        )
        try await Self.destination.updateTask(withId: id, from: completedTask, config: config)

        guard let reminder = Self.eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            XCTFail("Completed reminder not found")
            return
        }

        XCTAssertTrue(reminder.isCompleted)
        XCTAssertNotNil(reminder.completionDate)
    }

    func testMoveTask() async throws {
        let store = Self.eventStore
        let moveTargetName = Self.testListName + "-Move"

        // Create a second test list for the move target
        var moveList = store.calendars(for: .reminder).first { $0.title == moveTargetName }
        if moveList == nil {
            let calendar = EKCalendar(for: .reminder, eventStore: store)
            calendar.title = moveTargetName
            calendar.source = Self.testList!.source
            try store.saveCalendar(calendar, commit: true)
            moveList = calendar
        }

        // Clean up the move target list after the test
        addTeardownBlock {
            if let list = moveList {
                let predicate = store.predicateForReminders(in: [list])
                let reminders = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EKReminder], Error>) in
                    store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
                }
                for r in reminders { try? store.remove(r, commit: false) }
                try? store.commit()
                try? store.removeCalendar(list, commit: true)
            }
        }

        let task = SyncTask(title: "Move me")
        let id = try await Self.destination.createTask(from: task, inList: Self.testListName, config: config)

        try await Self.destination.moveTask(withId: id, toList: moveTargetName)

        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            XCTFail("Moved reminder not found")
            return
        }

        XCTAssertEqual(reminder.calendar.title, moveTargetName)
    }

    func testPriorityRoundTrip() async throws {
        let priorities: [(SyncTask.Priority, Int)] = [
            (.none, 0), (.low, 9), (.medium, 5), (.high, 1)
        ]

        for (priority, expectedRaw) in priorities {
            let task = SyncTask(title: "Priority \(priority)", priority: priority)
            let id = try await Self.destination.createTask(from: task, inList: Self.testListName, config: config)

            guard let reminder = Self.eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
                XCTFail("Reminder not found for priority \(priority)")
                continue
            }

            XCTAssertEqual(reminder.priority, expectedRaw, "Priority \(priority) should map to \(expectedRaw)")

            let roundTripped = SyncTask.fromReminder(reminder, listName: Self.testListName)
            XCTAssertEqual(roundTripped.priority, priority, "Priority should survive round-trip")
        }
    }

    func testTagsStoredInNotes() async throws {
        let task = SyncTask(
            title: "Tagged task",
            tags: ["#work", "#urgent"]
        )
        let id = try await Self.destination.createTask(from: task, inList: Self.testListName, config: config)

        guard let reminder = Self.eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            XCTFail("Reminder not found")
            return
        }

        XCTAssertNotNil(reminder.notes)
        XCTAssertTrue(reminder.notes!.contains("#work"))
        XCTAssertTrue(reminder.notes!.contains("#urgent"))

        let roundTripped = SyncTask.fromReminder(reminder, listName: Self.testListName)
        XCTAssertTrue(roundTripped.tags.contains("#work"))
        XCTAssertTrue(roundTripped.tags.contains("#urgent"))
    }

    func testGetAvailableLists() async throws {
        let lists = await Self.destination.getAvailableLists()
        XCTAssertTrue(lists.contains(Self.testListName), "Test list should appear in available lists")
    }

    // MARK: - Helpers

    private func deleteAllRemindersInTestList() async throws {
        guard let list = Self.testList else { return }
        let store = Self.eventStore
        let predicate = store.predicateForReminders(in: [list])
        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        for reminder in reminders {
            try store.remove(reminder, commit: false)
        }
        try store.commit()
    }
}
