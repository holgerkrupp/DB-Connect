import Foundation
import XCTest

final class PredicateBuilderTests: XCTestCase {
    func testBuildsSQLiteClauseBindingsAndWildcardEscaping() throws {
        let columns = [
            ColumnDescriptor(name: "id", declaredType: "INTEGER", isNullable: false, isPrimaryKey: true),
            ColumnDescriptor(name: "title", declaredType: "TEXT"),
            ColumnDescriptor(name: "price", declaredType: "REAL"),
            ColumnDescriptor(name: "payload", declaredType: "BLOB")
        ]

        let predicate = try PredicateBuilder.build(
            filters: [
                ColumnFilter(column: "title", op: .contains, value: "50%_off"),
                ColumnFilter(column: "price", op: .greaterOrEqual, value: "10")
            ],
            search: "Book",
            columns: columns,
            dialect: .sqlite
        )

        XCTAssertEqual(
            predicate.clause,
            #"CAST("title" AS TEXT) LIKE ? ESCAPE '\' AND "price" >= ? AND (CAST("id" AS TEXT) LIKE ? ESCAPE '\' OR CAST("title" AS TEXT) LIKE ? ESCAPE '\' OR CAST("price" AS TEXT) LIKE ? ESCAPE '\')"#
        )
        XCTAssertEqual(
            predicate.bindings,
            [
                .text(#"%50\%\_off%"#),
                .double(10),
                .text("%Book%"),
                .text("%Book%"),
                .text("%Book%")
            ]
        )
        XCTAssertEqual(predicate.nextIndex, 6)
    }

    func testBuildStartsPlaceholderNumberingFromRequestedIndex() throws {
        let columns = [
            ColumnDescriptor(name: "quantity", declaredType: "INTEGER", isNullable: false),
            ColumnDescriptor(name: "name", declaredType: "TEXT")
        ]

        let predicate = try PredicateBuilder.build(
            filters: [ColumnFilter(column: "quantity", op: .lessThan, value: "8")],
            search: "bolt",
            columns: columns,
            dialect: .postgres,
            startingAt: 3
        )

        XCTAssertEqual(
            predicate.clause,
            #""quantity" < $3 AND ("quantity"::text ILIKE $4 ESCAPE '\' OR "name"::text ILIKE $5 ESCAPE '\')"#
        )
        XCTAssertEqual(
            predicate.bindings,
            [.integer(8), .text("%bolt%"), .text("%bolt%")]
        )
        XCTAssertEqual(predicate.nextIndex, 6)
    }

    func testBuildRejectsUnknownFilterColumn() {
        let columns = [ColumnDescriptor(name: "title", declaredType: "TEXT")]

        XCTAssertThrowsError(
            try PredicateBuilder.build(
                filters: [ColumnFilter(column: "missing", op: .equals, value: "x")],
                search: nil,
                columns: columns,
                dialect: .sqlite
            )
        ) { error in
            guard case DatabaseError.invalidIdentifier(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Unknown column “missing”.")
        }
    }
}

final class ConnectionRuntimeAccessTests: XCTestCase {
    func testRDSIAMTokenIsStableForFixedInputs() throws {
        let date = ISO8601DateFormatter().date(from: "2026-07-22T10:15:30Z")!
        let token = try RDSIAMAuthTokenGenerator.makeToken(
            host: "db.example.us-east-1.rds.amazonaws.com",
            port: 3306,
            username: "db_user",
            region: "us-east-1",
            credentials: AWSCredentials(
                accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                sessionToken: "IQoJb3JpZ2luX2VjEOj//////////wEaCXVzLWVhc3QtMSJHMEUCIQDj"
            ),
            now: date
        )

        XCTAssertEqual(
            token,
            "db.example.us-east-1.rds.amazonaws.com:3306/?Action=connect&DBUser=db_user&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260722%2Fus-east-1%2Frds-db%2Faws4_request&X-Amz-Date=20260722T101530Z&X-Amz-Expires=900&X-Amz-Security-Token=IQoJb3JpZ2luX2VjEOj%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEaCXVzLWVhc3QtMSJHMEUCIQDj&X-Amz-SignedHeaders=host&X-Amz-Signature=86f824ef58e85dcc9236df9273411fc903a500f0ff3187a11464cc99b09c50d2"
        )
    }

    func testSecretResolverGeneratesIAMPasswordWithoutDiscardingStoredSessionToken() throws {
        let config = ConnectionConfig(
            driverID: "mysql",
            host: "db.example.us-east-1.rds.amazonaws.com",
            port: 3306,
            username: "app_user",
            authentication: DatabaseAuthenticationConfiguration(mode: .awsIAM, awsRegion: "us-east-1")
        )
        let stored = Secret(
            awsAccessKeyID: "AKIAIOSFODNN7EXAMPLE",
            awsSecretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            awsSessionToken: "session-token"
        )
        let date = ISO8601DateFormatter().date(from: "2026-07-22T10:15:30Z")!

        let resolved = try ConnectionRuntimeSecretResolver.resolve(config: config, secret: stored, now: date)

        XCTAssertEqual(resolved?.awsSessionToken, "session-token")
        XCTAssertNotNil(resolved?.password)
        XCTAssertTrue(resolved?.password?.contains("Action=connect") == true)
        XCTAssertTrue(resolved?.password?.contains("DBUser=app_user") == true)
    }

    func testSecretResolverRejectsIAMOnLocalSocket() {
        let config = ConnectionConfig(
            driverID: "mysql",
            username: "app_user",
            socketPath: "/tmp/mysql.sock",
            authentication: DatabaseAuthenticationConfiguration(mode: .awsIAM, awsRegion: "us-east-1")
        )

        XCTAssertThrowsError(try ConnectionRuntimeSecretResolver.resolve(config: config, secret: Secret())) { error in
            guard case DatabaseError.unsupported(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "AWS IAM authentication is not available for local socket connections.")
        }
    }
}

final class MySQLPrivilegeTests: XCTestCase {
    func testGrantParserKeepsDatabaseAndSingleTableScopesSeparate() {
        let grants = MySQLGrantParser.parse([
            "GRANT SELECT, INSERT ON `sales`.* TO 'app'@'%'",
            "GRANT UPDATE (`notes`), DELETE ON `sales`.`orders` TO 'app'@'%' WITH GRANT OPTION",
            "GRANT PROCESS ON *.* TO 'app'@'%'"
        ])

        XCTAssertEqual(grants.global, ["PROCESS"])
        XCTAssertEqual(grants.schema["sales"], ["INSERT", "SELECT"])

        let target = GrantTableTarget(database: "sales", table: "orders")
        XCTAssertEqual(grants.table[target], ["DELETE", "UPDATE"])
        XCTAssertEqual(grants.tableGrantOption[target], true)
    }

    func testGrantParserUnescapesWildcardCharactersInScopedObjectNames() {
        let grants = MySQLGrantParser.parse([
            #"GRANT SELECT ON `claude\_test`.`audit\%2026` TO 'app'@'%'"#
        ])

        let target = GrantTableTarget(database: "claude_test", table: "audit%2026")
        XCTAssertEqual(grants.table[target], ["SELECT"])
    }

    func testMySQLAdminCapabilityResolverDistinguishesVisibleProcessesAndFlushPrivilege() {
        let restricted = MySQLAdminCapabilityResolver.resolve(from: [
            "GRANT SELECT ON `sales`.* TO 'app'@'%'"
        ])
        XCTAssertEqual(restricted.processVisibility, .ownSessions)
        XCTAssertFalse(restricted.canFlushPrivileges)

        let elevated = MySQLAdminCapabilityResolver.resolve(from: [
            "GRANT PROCESS, RELOAD ON *.* TO 'admin'@'%'"
        ])
        XCTAssertEqual(elevated.processVisibility, .allSessions)
        XCTAssertTrue(elevated.canFlushPrivileges)
    }
}

final class QueryFavoriteSnippetTests: XCTestCase {
    func testSnippetExpansionSupportsDynamicPlaceholdersSelectionsAndCursor() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 7,
            day: 22,
            hour: 10,
            minute: 30
        ))!
        let context = QueryFavoriteContext(
            connectionName: "Production",
            databaseName: "analytics",
            tableName: "orders",
            now: date
        )

        let expansion = QueryFavoriteSnippetExpander.expand(
            "SELECT ${1:*} FROM $TABLE WHERE db = '$DATABASE' AND ran_at >= '$DATE' $0",
            context: context
        )

        XCTAssertEqual(
            expansion.text,
            "SELECT * FROM orders WHERE db = 'analytics' AND ran_at >= '2026-07-22' "
        )
        XCTAssertEqual(expansion.selectedRange, 7..<8)
        XCTAssertEqual(expansion.cursorOffset, expansion.text.count)
    }

    func testSnippetExpansionKeepsUnknownTokensLiteralAndFallsBackForMissingTable() {
        let context = QueryFavoriteContext(
            connectionName: "Warehouse",
            databaseName: "warehouse",
            tableName: nil,
            now: .distantPast
        )

        let expansion = QueryFavoriteSnippetExpander.expand(
            "SELECT ${PLACEHOLDER:columns} FROM $TABLE /* $UNKNOWN */",
            context: context
        )

        XCTAssertEqual(expansion.text, "SELECT columns FROM table_name /* $UNKNOWN */")
        XCTAssertEqual(expansion.selectedRange, 7..<14)
    }
}

final class SQLScriptParserTests: XCTestCase {
    func testParserTracksSimpleStatementLineNumbers() {
        let statements = SQLScriptParser.parse("SELECT 1;\n\nSELECT 2;\n")

        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].sql, "SELECT 1")
        XCTAssertEqual(statements[0].startLine, 1)
        XCTAssertEqual(statements[0].endLine, 1)
        XCTAssertEqual(statements[1].sql, "SELECT 2")
        XCTAssertEqual(statements[1].startLine, 3)
        XCTAssertEqual(statements[1].endLine, 3)
    }

    func testParserKeepsMySQLDelimiterBlocksTogether() {
        let script = """
        DELIMITER $$
        CREATE TRIGGER audit_before_insert BEFORE INSERT ON users
        FOR EACH ROW
        BEGIN
          SET NEW.created_at = NOW();
        END$$
        DELIMITER ;
        SELECT 1;
        """

        let statements = SQLScriptParser.parse(script)

        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("CREATE TRIGGER audit_before_insert"))
        XCTAssertTrue(statements[0].sql.contains("SET NEW.created_at = NOW()"))
        XCTAssertEqual(statements[1].sql, "SELECT 1")
    }
}

final class SQLiteFileAccessRequirementTests: XCTestCase {
    func testIssueIsNilWhenReadOnlyFileBookmarkExists() {
        let issue = SQLiteFileAccessRequirement.issue(
            path: "/outside/sandbox/app.sqlite",
            hasFileBookmark: true,
            hasContainerBookmark: false,
            isReadOnly: true
        )

        XCTAssertNil(issue)
    }

    func testIssueIsNilForReadableLocalFileWithoutBookmarksWhenReadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-access-\(UUID().uuidString).sqlite")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let issue = SQLiteFileAccessRequirement.issue(
            path: url.path,
            hasFileBookmark: false,
            hasContainerBookmark: false,
            isReadOnly: true
        )

        XCTAssertNil(issue)
    }

    func testIssueExplainsHowToRecoverWhenBookmarkIsMissing() {
        let issue = SQLiteFileAccessRequirement.issue(
            path: "/definitely/missing/app.sqlite",
            hasFileBookmark: false,
            hasContainerBookmark: false,
            isReadOnly: false
        )

        XCTAssertEqual(
            issue,
            "DB Connect is not allowed to open “app.sqlite” on this Mac yet. Edit the connection and choose the database file again to grant access."
        )
    }

    func testWritableConnectionNeedsFolderAccessForCompanionFiles() {
        let issue = SQLiteFileAccessRequirement.issue(
            path: "/outside/sandbox/app.sqlite",
            hasFileBookmark: true,
            hasContainerBookmark: false,
            isReadOnly: false,
            fileManager: FileManager.default
        )

        XCTAssertEqual(
            issue,
            "DB Connect also needs access to the folder containing “app.sqlite” so SQLite can read and write its companion WAL or journal files. Grant folder access for this connection on this Mac."
        )
    }

    func testWritableConnectionIsAllowedWhenFolderAccessExists() {
        let issue = SQLiteFileAccessRequirement.issue(
            path: "/outside/sandbox/app.sqlite",
            hasFileBookmark: true,
            hasContainerBookmark: true,
            isReadOnly: false
        )

        XCTAssertNil(issue)
    }

    func testRemoteOnlyOwnerUsesRecordedDeviceNameWhenFileIsNotReadableHere() {
        let owner = SQLiteFileAccessRequirement.unavailableOnOtherDeviceOwner(
            path: "/definitely/missing/app.sqlite",
            ownerDeviceID: "device-a",
            ownerDeviceName: "Holger's MacBook Pro",
            currentDeviceID: "device-b"
        )

        XCTAssertEqual(owner, "Holger's MacBook Pro")
    }

    func testRemoteOnlyOwnerIsNilOnOwningDevice() {
        let owner = SQLiteFileAccessRequirement.unavailableOnOtherDeviceOwner(
            path: "/definitely/missing/app.sqlite",
            ownerDeviceID: "device-a",
            ownerDeviceName: "Holger's MacBook Pro",
            currentDeviceID: "device-a"
        )

        XCTAssertNil(owner)
    }
}
