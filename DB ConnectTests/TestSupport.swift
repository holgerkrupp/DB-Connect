import Foundation
import XCTest

enum TestSupport {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func fixtureURL(named name: String) -> URL {
        repoRoot.appendingPathComponent("examples").appendingPathComponent(name)
    }

    static func withSQLiteSession<T>(
        fixture name: String,
        perform: (any DatabaseSession) async throws -> T
    ) async throws -> T {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBConnectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let source = fixtureURL(named: name)
        let destination = workspace.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)

        let session = try await SQLiteDriver().connect(
            config: ConnectionConfig(driverID: SQLiteDriver.id, database: destination.path),
            secret: nil
        )

        do {
            let result = try await perform(session)
            await session.close()
            try? FileManager.default.removeItem(at: workspace)
            return result
        } catch {
            await session.close()
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    static func columnIndex(_ name: String, in result: ResultSet, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let index = result.columns.firstIndex(where: { $0.name == name }) else {
            XCTFail("Missing column \(name)", file: file, line: line)
            return 0
        }
        return index
    }
}

final class MonitorRuleTests: XCTestCase {
    func testFirstDeltaRunEstablishesBaselineWithoutAlerting() {
        let rule = MonitorRule(kind: .changedByAtLeast, threshold: 2)

        XCTAssertFalse(rule.fires(
            previous: nil,
            observation: .init(value: 10, rowCount: 1)
        ))
        XCTAssertFalse(rule.fires(
            previous: 10,
            observation: .init(value: 11.5, rowCount: 1)
        ))
        XCTAssertTrue(rule.fires(
            previous: 10,
            observation: .init(value: 12, rowCount: 1)
        ))
    }

    func testThresholdRulesOnlyFireOnCrossing() {
        let rule = MonitorRule(kind: .above, threshold: 100)

        XCTAssertTrue(rule.fires(previous: 99, observation: .init(value: 101, rowCount: 1)))
        XCTAssertFalse(rule.fires(previous: 101, observation: .init(value: 102, rowCount: 1)))
    }

    func testQuietHoursCanWrapAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let late = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 23))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 8))!

        XCTAssertTrue(NotificationGate.isQuiet(now: late, start: 22, end: 7, calendar: calendar))
        XCTAssertFalse(NotificationGate.isQuiet(now: morning, start: 22, end: 7, calendar: calendar))
    }
}
