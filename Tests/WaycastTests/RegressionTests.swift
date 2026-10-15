import XCTest
@testable import Waycast

final class RegressionTests: XCTestCase {
    @MainActor
    func testResetRejectsCallbacksForRememberedQuery() async throws {
        let model = SearchViewModel()
        model.query = "test"
        model.queryChanged()
        model.reset(keepingQuery: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.query, "test")
        XCTAssertTrue(model.appResults.isEmpty)
        XCTAssertTrue(model.fileResults.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    @MainActor
    func testWhitespaceQueryCollapsesResults() {
        let model = SearchViewModel()
        model.query = "\n\t "
        model.queryChanged()
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.listHeight, 0)
    }

    @MainActor
    func testNewQueryClearsPreviousSelectableResults() {
        let model = SearchViewModel()
        model.appResults = [SearchItem(id: "old", kind: .app, title: "Old",
                                      subtitle: "", url: URL(fileURLWithPath: "/old.app"))]
        model.query = "new"
        model.queryChanged()
        XCTAssertTrue(model.allResults.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        model.reset()
    }

    func testClipboardFirstSaveAndReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let controller = ClipboardController(storeURL: url)
        controller.save()
        XCTAssertEqual(try Data(contentsOf: url), Data("[]".utf8))
        try Data("invalid".utf8).write(to: url)
        controller.save()
        XCTAssertEqual(try Data(contentsOf: url), Data("[]".utf8))
    }

    func testRateFieldKeepsFixedWidthAtUnitBoundaries() {
        for rate in [0, 9.96, 999.6, 999_600, 1e12, Double.nan, .infinity, -1] {
            XCTAssertEqual(RateFormat.short(rate).count, 4)
        }
    }
}
