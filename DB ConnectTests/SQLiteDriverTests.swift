import XCTest

final class SQLiteDriverTests: XCTestCase {
    func testTablesDefinitionsAndDeferredDefinitionsComeFromFixture() async throws {
        try await TestSupport.withSQLiteSession(fixture: "example.db") { session in
            let tables = try await session.tables()
            XCTAssertEqual(
                tables.map(\.name),
                ["audit_log", "authors", "book_summaries", "books", "scratch_notes"]
            )

            let books = try await session.describe(table: "books", schema: nil)
            XCTAssertEqual(books.primaryKey, ["id"])
            XCTAssertTrue(books.isEditable)

            let generated = try XCTUnwrap(books.columns.first(where: { $0.name == "title_lower" }))
            XCTAssertTrue(generated.isGenerated)

            let definition = try await session.definitionSQL(for: books)
            XCTAssertNotNil(definition)
            XCTAssertTrue(definition?.contains("CREATE TABLE books") == true)
            XCTAssertTrue(definition?.contains("title_lower TEXT GENERATED ALWAYS") == true)

            let deferred = try await session.deferredDefinitionSQL(for: books)
            XCTAssertEqual(deferred.count, 2)
            XCTAssertTrue(deferred.contains(where: { $0.contains("CREATE INDEX idx_books_title") }))
            XCTAssertTrue(deferred.contains(where: { $0.contains("CREATE TRIGGER books_audit_insert") }))

            let scratchNotes = try await session.describe(table: "scratch_notes", schema: nil)
            XCTAssertFalse(scratchNotes.isEditable)
            XCTAssertEqual(
                scratchNotes.readOnlyReason,
                "This table has no primary key, so rows cannot be identified safely."
            )
        }
    }

    func testFetchCountSearchAndSortUseLiveSQLiteData() async throws {
        try await TestSupport.withSQLiteSession(fixture: "example.db") { session in
            let firstPage = try await session.fetch(
                RowRequest(
                    table: "books",
                    sort: [SortTerm(column: "price", ascending: false)],
                    limit: 2
                )
            )

            XCTAssertEqual(firstPage.rows.count, 2)
            XCTAssertTrue(firstPage.hasMore)
            let titleIndex = TestSupport.columnIndex("title", in: firstPage)
            XCTAssertEqual(firstPage.rows[0][titleIndex], .text("Dune"))
            XCTAssertEqual(firstPage.rows[1][titleIndex], .text("The Left Hand of Darkness"))

            let count = try await session.count(
                RowRequest(
                    table: "books",
                    filters: [ColumnFilter(column: "genre", op: .equals, value: "Science Fiction")]
                )
            )
            XCTAssertEqual(count, 4)

            let searchResult = try await session.fetch(
                RowRequest(table: "books", search: "earthsea", limit: 10)
            )
            XCTAssertEqual(searchResult.rows.count, 1)
            XCTAssertEqual(searchResult.rows[0][titleIndex], .text("A Wizard of Earthsea"))

            do {
                _ = try await session.fetch(
                    RowRequest(
                        table: "books",
                        sort: [SortTerm(column: "missing_column")],
                        limit: 10
                    )
                )
                XCTFail("Expected fetch to reject an unknown sort column.")
            } catch let error as DatabaseError {
                XCTAssertEqual(error, .invalidIdentifier("Unknown column “missing_column”."))
            }
        }
    }

    func testApplyCommitsSuccessfulMutationsAndRollsBackFailedBatch() async throws {
        try await TestSupport.withSQLiteSession(fixture: "example.db") { session in
            let authors = try await session.describe(table: "authors", schema: nil)
            let preview = try session.preview(
                [.insert(values: [
                    "name": .text("N. K. Jemisin"),
                    "country": .text("USA"),
                    "active": .integer(1)
                ])],
                to: authors
            )
            XCTAssertEqual(preview.count, 1)
            XCTAssertTrue(preview[0].contains(#"INSERT INTO "authors""#))
            XCTAssertTrue(preview[0].contains("N. K. Jemisin"))

            let insertedAuthor = try await session.apply(
                [.insert(values: [
                    "name": .text("N. K. Jemisin"),
                    "country": .text("USA"),
                    "active": .integer(1)
                ])],
                to: authors
            )
            XCTAssertEqual(insertedAuthor.affectedRows, 1)

            let authorCheck = try await session.query(
                Statement("SELECT name FROM authors WHERE name = ?", bindings: [.text("N. K. Jemisin")])
            )
            XCTAssertEqual(authorCheck.rows.count, 1)

            let books = try await session.describe(table: "books", schema: nil)

            do {
                _ = try await session.apply(
                    [
                        .insert(values: [
                            "author_id": .integer(1),
                            "title": .text("Tehanu"),
                            "genre": .text("Fantasy"),
                            "price": .double(13.5),
                            "published_at": .text("1990-01-01T00:00:00Z"),
                            "is_featured": .integer(0)
                        ]),
                        .insert(values: [
                            "author_id": .integer(9_999),
                            "title": .text("Broken Foreign Key"),
                            "genre": .text("Fantasy"),
                            "price": .double(1.0),
                            "published_at": .text("1990-01-01T00:00:00Z"),
                            "is_featured": .integer(0)
                        ])
                    ],
                    to: books
                )
                XCTFail("Expected the batch to fail and roll back.")
            } catch let error as DatabaseError {
                guard case .queryFailed(_, let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(message.localizedCaseInsensitiveContains("foreign key"))
            }

            let rolledBack = try await session.query(
                Statement("SELECT COUNT(*) AS matches FROM books WHERE title = ?", bindings: [.text("Tehanu")])
            )
            XCTAssertEqual(rolledBack.scalar(column: "matches"), 0)
        }
    }

    func testSchemaAdminCreateAndDropTableOnSQLite() async throws {
        try await TestSupport.withSQLiteSession(fixture: "warehouse.db") { session in
            let schemaAdmin = await session.schemaAdmin
            XCTAssertEqual(schemaAdmin, .localFile)

            try await session.createTable(
                NewTableSpec(
                    name: "restock_requests",
                    columns: [
                        NewColumn(
                            name: "id",
                            type: .integer,
                            isNullable: false,
                            isPrimaryKey: true,
                            isAutoIncrement: true
                        ),
                        NewColumn(name: "sku", type: .varchar, length: 32, isNullable: false),
                        NewColumn(name: "quantity", type: .integer, isNullable: false, defaultValue: "1")
                    ]
                )
            )

            let tablesAfterCreate = try await session.tables()
            XCTAssertTrue(tablesAfterCreate.contains(where: { $0.name == "restock_requests" }))

            let created = try await session.describe(table: "restock_requests", schema: nil)
            try await session.dropTable(created)

            let tablesAfterDrop = try await session.tables()
            XCTAssertFalse(tablesAfterDrop.contains(where: { $0.name == "restock_requests" }))
        }
    }
}
