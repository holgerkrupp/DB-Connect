import Foundation
import XCTest

final class FavoriteOrganizationTests: XCTestCase {
    func testSearchMatchesAllFavoriteFieldsWithLocaleAwareComparison() {
        let fields = FavoriteSearchFields(
            name: "Production München",
            host: "db.example.com",
            username: "reporting",
            database: "analytics",
            driver: "PostgreSQL",
            tag: "critical",
            group: "Operations"
        )

        XCTAssertTrue(fields.matches("EXAMPLE.COM", locale: Locale(identifier: "en_US")))
        XCTAssertTrue(fields.matches("munchen", locale: Locale(identifier: "de_DE")))
        XCTAssertTrue(fields.matches("postgres", locale: Locale(identifier: "en_US")))
        XCTAssertTrue(fields.matches("operations", locale: Locale(identifier: "en_US")))
        XCTAssertFalse(fields.matches("staging", locale: Locale(identifier: "en_US")))
    }

    func testManualOrderWinsAndLegacyOrderBreaksTies() {
        let old = FavoriteOrderingKey(
            favoriteOrder: 0,
            legacyOrder: 2,
            createdAt: .now,
            stableID: "old"
        )
        let manuallyPlaced = FavoriteOrderingKey(
            favoriteOrder: 1,
            legacyOrder: 99,
            createdAt: .now,
            stableID: "manual"
        )
        XCTAssertTrue(FavoriteOrderingKey.orderedBefore(manuallyPlaced, old))

        let first = FavoriteOrderingKey(
            favoriteOrder: 0,
            legacyOrder: 1,
            createdAt: .now,
            stableID: "first"
        )
        let second = FavoriteOrderingKey(
            favoriteOrder: 0,
            legacyOrder: 1,
            createdAt: first.createdAt,
            stableID: "second"
        )
        XCTAssertTrue(FavoriteOrderingKey.orderedBefore(first, second))
    }

    func testRemovingGroupOnlyClearsMembershipReference() {
        let groupID = UUID()
        let otherGroupID = UUID()

        XCTAssertNil(FavoriteGroupSemantics.groupID(afterRemoving: groupID, from: groupID))
        XCTAssertEqual(
            FavoriteGroupSemantics.groupID(afterRemoving: groupID, from: otherGroupID),
            otherGroupID
        )
        XCTAssertNil(FavoriteGroupSemantics.groupID(afterRemoving: groupID, from: nil))
    }

    func testLauncherRestorationRejectsUnknownFavorites() {
        let id = UUID()
        XCTAssertEqual(
            LauncherStateRestoration.decode("favorite:\(id.uuidString)", availableFavoriteIDs: []),
            .quickConnect
        )
        XCTAssertEqual(
            LauncherStateRestoration.decode("favorite:\(id.uuidString)", availableFavoriteIDs: [id]),
            .favorite(id)
        )
        XCTAssertEqual(LauncherStateRestoration.encode(.monitors), "monitors")
    }

    func testQuickConnectSecretsAreAlwaysRuntimeOnly() {
        XCTAssertTrue(LauncherStateRestoration.usesRuntimeSecret(selection: .quickConnect, hasTypedSecret: false))
        XCTAssertTrue(LauncherStateRestoration.usesRuntimeSecret(selection: .favorite(UUID()), hasTypedSecret: true))
        XCTAssertFalse(LauncherStateRestoration.usesRuntimeSecret(selection: .favorite(UUID()), hasTypedSecret: false))
    }
}
