import Foundation
import XCTest
@testable import LabelKit

/// Issue #6: a framework call that never returns must not hold the caller forever.
final class BoundedTests: XCTestCase {
    func testLaneGivesUpAndStaysStuckUntilTheCallReturns() {
        let lane = Lane("test", limit: 0.2)
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        XCTAssertNil(lane.run { release.wait(); return 1 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(lane.isStuck)

        // While that call is out, the lane doesn't call again: no second thread left hanging, no second wait.
        let skipped = Date()
        XCTAssertNil(lane.run { 2 })
        XCTAssertLessThan(Date().timeIntervalSince(skipped), 0.1)

        release.signal()
        let deadline = Date().addingTimeInterval(5)
        while lane.isStuck && Date() < deadline { usleep(10_000) }
        XCTAssertFalse(lane.isStuck)
        XCTAssertEqual(lane.run { 3 }, 3)
    }

    func testBoundedRunFallsBackAfterTheLimit() async {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let queue = DispatchQueue(label: "test.bounded")
        let value = await Bounded.run(on: queue, limit: 0.2, { release.wait(); return "work" }, fallback: { "fallback" })
        XCTAssertEqual(value, "fallback")
        let fast = await Bounded.run(on: DispatchQueue(label: "test.fast"), limit: 5, { "work" }, fallback: { "fallback" })
        XCTAssertEqual(fast, "work")
    }
}
