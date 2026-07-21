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
