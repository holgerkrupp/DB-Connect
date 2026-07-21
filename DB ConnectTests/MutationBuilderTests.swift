import XCTest

final class MutationBuilderTests: XCTestCase {
    func testInsertStatementSortsColumnsIntoStableOrder() throws {
        let table = TableDescriptor(
            name: "books",
            columns: [ColumnDescriptor(name: "id", declaredType: "INTEGER", isPrimaryKey: true)]
        )

        let statement = try MutationBuilder.statement(
            for: .insert(values: [
                "title": .text("Kindred"),
                "author_id": .integer(2)
            ]),
            table: table,
            dialect: .sqlite
        )

        XCTAssertEqual(
            statement,
            Statement(
                #"INSERT INTO "books" ("author_id", "title") VALUES (?, ?)"#,
                bindings: [.integer(2), .text("Kindred")]
            )
        )
    }

    func testDeleteStatementSortsCompositeKeyAndNumbersPostgresBindings() throws {
        let table = TableDescriptor(
            name: "line_items",
            schema: "sales",
            columns: [
                ColumnDescriptor(name: "order_id", declaredType: "INTEGER", isNullable: false, isPrimaryKey: true),
                ColumnDescriptor(name: "product_id", declaredType: "INTEGER", isNullable: false, isPrimaryKey: true)
            ]
        )

        let statement = try MutationBuilder.statement(
            for: .delete(primaryKey: [
                "product_id": .integer(7),
                "order_id": .integer(3)
            ]),
            table: table,
            dialect: .postgres
        )

        XCTAssertEqual(
            statement,
            Statement(
                #"DELETE FROM "sales"."line_items" WHERE "order_id" = $1 AND "product_id" = $2"#,
                bindings: [.integer(3), .integer(7)]
            )
        )
    }

    func testUpdateRejectsReadOnlyTableWithoutPrimaryKey() {
        let table = TableDescriptor(
            name: "scratch_notes",
            columns: [ColumnDescriptor(name: "note", declaredType: "TEXT")]
        )

        XCTAssertThrowsError(
            try MutationBuilder.statement(
                for: .update(primaryKey: [:], values: ["note": .text("Updated")]),
                table: table,
                dialect: .sqlite
            )
        ) { error in
            guard case DatabaseError.readOnly(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "This table has no primary key, so rows cannot be identified safely.")
        }
    }
}
