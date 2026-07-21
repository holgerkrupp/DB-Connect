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
