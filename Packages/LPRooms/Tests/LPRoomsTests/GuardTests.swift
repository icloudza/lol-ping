import XCTest
@testable import LPRooms

// Ported from upstream's tests/main/replayGuard.test.ts, rateLimiter.test.ts and floodGuard.test.ts.

private let NOW = 1_780_000_000_000

final class ReplayGuardTests: XCTestCase {
    private func guardian() -> ReplayGuard { ReplayGuard(now: { NOW }) }

    func testAcceptsIncreasingSequenceNumbersAndRejectsRepeats() {
        let g = guardian()
        XCTAssertEqual(g.accept(peer: "a", seq: 1, ts: NOW), .ok)
        XCTAssertEqual(g.accept(peer: "a", seq: 2, ts: NOW), .ok)
        XCTAssertEqual(g.accept(peer: "a", seq: 2, ts: NOW), .replay)
    }

    func testAcceptsLatePacketsInsideThe64WindowOnce() {
        let g = guardian()
        _ = g.accept(peer: "a", seq: 100, ts: NOW)
        XCTAssertEqual(g.accept(peer: "a", seq: 90, ts: NOW), .ok)
        XCTAssertEqual(g.accept(peer: "a", seq: 90, ts: NOW), .replay)
        XCTAssertEqual(g.accept(peer: "a", seq: 36, ts: NOW), .replay) // 64 behind
        XCTAssertEqual(g.accept(peer: "a", seq: 37, ts: NOW), .ok) // 63 behind: the edge of the window
        XCTAssertEqual(g.accept(peer: "a", seq: 70, ts: NOW), .ok)
    }

    func testTheWindowSlides() {
        let g = guardian()
        for seq in 1...200 { XCTAssertEqual(g.accept(peer: "a", seq: seq, ts: NOW), .ok) }
        for seq in 137...200 { XCTAssertEqual(g.accept(peer: "a", seq: seq, ts: NOW), .replay) }
        XCTAssertEqual(g.accept(peer: "a", seq: 263, ts: NOW), .ok) // 63 ahead: 200 is now the oldest it remembers
        XCTAssertEqual(g.accept(peer: "a", seq: 200, ts: NOW), .replay)
        XCTAssertEqual(g.accept(peer: "a", seq: 201, ts: NOW), .ok) // skipped over, still inside
        XCTAssertEqual(g.accept(peer: "a", seq: 199, ts: NOW), .replay)
    }

    func testForgetsTheWindowAfterABigJump() {
        let g = guardian()
        _ = g.accept(peer: "a", seq: 5, ts: NOW)
        XCTAssertEqual(g.accept(peer: "a", seq: 500, ts: NOW), .ok)
        XCTAssertEqual(g.accept(peer: "a", seq: 5, ts: NOW), .replay)
        XCTAssertEqual(g.accept(peer: "a", seq: 499, ts: NOW), .ok)
    }

    func testKeepsPeersApart() {
        let g = guardian()
        _ = g.accept(peer: "a", seq: 1, ts: NOW)
        XCTAssertEqual(g.accept(peer: "b", seq: 1, ts: NOW), .ok)
    }

    func testRejectsTimestampsMoreThan10MinutesOff() {
        let g = guardian()
        XCTAssertEqual(g.accept(peer: "a", seq: 1, ts: NOW + 600_000), .ok)
        XCTAssertEqual(g.accept(peer: "a", seq: 2, ts: NOW + 600_001), .stale)
        XCTAssertEqual(g.accept(peer: "a", seq: 3, ts: NOW - 600_001), .stale)
    }

    func testAStalePacketDoesNotUseUpItsSequenceNumber() {
        let g = guardian()
        XCTAssertEqual(g.accept(peer: "a", seq: 1, ts: NOW + 900_000), .stale)
        XCTAssertEqual(g.accept(peer: "a", seq: 1, ts: NOW), .ok)
    }

    func testRejectsEverythingFromAPeerThatSaidBye() {
        let g = guardian()
        _ = g.accept(peer: "a", seq: 1, ts: NOW)
        g.markGone("a")
        XCTAssertEqual(g.accept(peer: "a", seq: 2, ts: NOW), .gone)
    }
}

final class RateLimiterTests: XCTestCase {
    private var now = 0
    private lazy var rl = RateLimiter(now: { [unowned self] in self.now })

    func testAllowsABurstUpToTheLimitThenRefillsOverTime() {
        for _ in 0..<5 { XCTAssertTrue(rl.allow("a", perSecond: 5)) }
        XCTAssertFalse(rl.allow("a", perSecond: 5))
        now += 200
        XCTAssertTrue(rl.allow("a", perSecond: 5))
        XCTAssertFalse(rl.allow("a", perSecond: 5))
    }

    func testNeverStoresMoreThanOneSecondOfTokens() {
        _ = rl.allow("a", perSecond: 2)
        now += 60_000
        XCTAssertEqual([rl.allow("a", perSecond: 2), rl.allow("a", perSecond: 2), rl.allow("a", perSecond: 2)], [true, true, false])
    }

    func testTreats0AsUnlimited() {
        for _ in 0..<1000 { XCTAssertTrue(rl.allow("a", perSecond: 0)) }
    }

    func testAllowsABurstBiggerThanTheRateWhenAsked() {
        for _ in 0..<10 { XCTAssertTrue(rl.allow("a", perSecond: 5, burst: 10)) }
        XCTAssertFalse(rl.allow("a", perSecond: 5, burst: 10))
        now += 200
        XCTAssertTrue(rl.allow("a", perSecond: 5, burst: 10))
        XCTAssertFalse(rl.allow("a", perSecond: 5, burst: 10))
    }

    func testKeepsKeysApartAndForgetResetsOne() {
        XCTAssertTrue(rl.allow("a", perSecond: 1))
        XCTAssertTrue(rl.allow("b", perSecond: 1))
        XCTAssertFalse(rl.allow("a", perSecond: 1))
        rl.forget("a")
        XCTAssertTrue(rl.allow("a", perSecond: 1))
        XCTAssertEqual(rl.size, 2)
        rl.clear()
        XCTAssertEqual(rl.size, 0)
    }
}

final class FloodGuardTests: XCTestCase {
    private var now = 0
    private lazy var g = FloodGuard(now: { [unowned self] in self.now }, limits: FloodLimits(perIp: 100, total: 800, maxTracked: 1024))

    func testDefaultsAreUpstreams() {
        XCTAssertEqual(FloodLimits.default, FloodLimits(perIp: 100, total: 800, maxTracked: 1024))
    }

    func testLimitsOneAddressToItsOwnBudget() {
        XCTAssertEqual((0..<500).filter { _ in g.allow("10.0.0.9") }.count, 100)
    }

    func testCapsTheTotalEvenWhenEveryPacketClaimsADifferentSource() {
        XCTAssertEqual((0..<5000).filter { i in g.allow("10.\((i >> 16) & 255).\((i >> 8) & 255).\(i & 255)") }.count, 800)
    }

    func testNeverTracksMoreThanMaxTrackedAddresses() {
        for i in 0..<20_000 {
            _ = g.allow("ip\(i)")
            if i % 500 == 0 { now += 1000 }
        }
        XCTAssertLessThanOrEqual(g.tracked, 1024)
    }

    func testRefillsOverTime() {
        for _ in 0..<100 { _ = g.allow("a") }
        XCTAssertFalse(g.allow("a"))
        now += 1000
        XCTAssertTrue(g.allow("a"))
    }
}
