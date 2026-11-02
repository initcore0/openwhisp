import XCTest
import Darwin
@testable import OpenWhispCore

/// The app-side Agent Bridge connection limits: a concurrent-connection cap and
/// bounded reads, so a client that connects and goes quiet can't pin a thread
/// forever (BUG_HUNT_2026-07, "UNIX bridge server: unbounded thread-per-connection
/// with no read/write timeouts"). The reader is driven over a real socket pair —
/// the same read() + SO_RCVTIMEO path AgentBridgeServer runs.
final class BridgeConnectionPolicyTests: XCTestCase {

    private var pair: [Int32] = [-1, -1]

    override func setUp() {
        super.setUp()
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    }

    override func tearDown() {
        for fd in pair where fd >= 0 { close(fd) }
        super.tearDown()
    }

    /// Run `reader.next()` off the test thread so a regression (an unbounded
    /// read) fails the expectation instead of hanging the suite.
    private func nextEvent(_ reader: BridgeConnectionReader, within seconds: TimeInterval) -> BridgeConnectionReader.Event? {
        let done = expectation(description: "next() returned")
        var event: BridgeConnectionReader.Event?
        DispatchQueue.global().async {
            event = reader.next()
            done.fulfill()
        }
        wait(for: [done], timeout: seconds)
        return event
    }

    // MARK: - Reader

    func testQuietPeerIsClosedAfterTheIdleTimeout() {
        let reader = BridgeConnectionReader(fd: pair[0], pollInterval: 0.05, idleTimeout: 0.3,
                                            isRunning: { true })
        let started = Date()
        XCTAssertEqual(nextEvent(reader, within: 3), .idleTimeout)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
    }

    func testStopIsNoticedWithinAPollTick() {
        let running = Locked(true)
        let reader = BridgeConnectionReader(fd: pair[0], pollInterval: 0.05, idleTimeout: 60,
                                            isRunning: { running.value })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { running.value = false }
        XCTAssertEqual(nextEvent(reader, within: 3), .stopped)
    }

    func testDataIsDelivered() {
        let reader = BridgeConnectionReader(fd: pair[0], pollInterval: 0.05, idleTimeout: 60,
                                            isRunning: { true })
        let msg = Array("{\"a\":1}\n".utf8)
        XCTAssertEqual(write(pair[1], msg, msg.count), msg.count)
        XCTAssertEqual(nextEvent(reader, within: 3), .data(Data(msg)))
    }

    func testPeerCloseIsReported() {
        let reader = BridgeConnectionReader(fd: pair[0], pollInterval: 0.05, idleTimeout: 60,
                                            isRunning: { true })
        close(pair[1]); pair[1] = -1
        XCTAssertEqual(nextEvent(reader, within: 3), .closed)
    }

    func testTimeSpentOnARequestDoesNotCountAsIdle() {
        let reader = BridgeConnectionReader(fd: pair[0], pollInterval: 0.05, idleTimeout: 0.4,
                                            isRunning: { true })
        Thread.sleep(forTimeInterval: 0.5) // "running a dictate" past the idle window
        reader.markActive()                // request finished
        let started = Date()
        XCTAssertEqual(nextEvent(reader, within: 3), .idleTimeout)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3,
                                    "idle clock restarted, not closed immediately")
    }

    func testWritesToAPeerThatNeverReadsAreBounded() {
        _ = BridgeConnectionReader(fd: pair[0], pollInterval: 0.05, idleTimeout: 60,
                                   writeTimeout: 0.2, isRunning: { true })
        let done = expectation(description: "writes gave up")
        var lastResult = 0
        DispatchQueue.global().async {
            let chunk = [UInt8](repeating: 0x41, count: 65536)
            for _ in 0..<1000 { // far more than any socket buffer
                lastResult = write(self.pair[0], chunk, chunk.count)
                if lastResult < 0 { break }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertLessThan(lastResult, 0, "SO_SNDTIMEO made write() fail instead of blocking")
    }

    // MARK: - Verdicts

    func testReadTimeoutVerdicts() {
        XCTAssertEqual(BridgeConnectionPolicy.afterReadTimeout(idleFor: 1, isRunning: true, idleTimeout: 10),
                       .keepWaiting)
        XCTAssertEqual(BridgeConnectionPolicy.afterReadTimeout(idleFor: 10, isRunning: true, idleTimeout: 10),
                       .closeIdle)
        XCTAssertEqual(BridgeConnectionPolicy.afterReadTimeout(idleFor: 1, isRunning: false, idleTimeout: 10),
                       .closeStopped)
    }

    // MARK: - Limiter

    func testLimiterCapsAndReleases() {
        let limiter = BridgeConnectionLimiter(limit: 2)
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertFalse(limiter.tryAcquire(), "over the cap")
        limiter.release()
        XCTAssertTrue(limiter.tryAcquire(), "a closed connection frees its slot")
        XCTAssertEqual(limiter.active, 2)
    }

    func testLimiterNeverExceedsItsCapUnderContention() {
        let limiter = BridgeConnectionLimiter(limit: 8)
        let granted = Locked(0)
        let peak = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            guard limiter.tryAcquire() else { return }
            granted.mutate { $0 += 1 }
            let now = limiter.active
            peak.mutate { $0 = max($0, now) }
            limiter.release()
        }
        XCTAssertLessThanOrEqual(peak.value, 8)
        XCTAssertGreaterThan(granted.value, 0)
        XCTAssertEqual(limiter.active, 0)
    }

    func testDefaultCapIsBounded() {
        XCTAssertGreaterThan(BridgeConnectionPolicy.maxConcurrentConnections, 4)
        XCTAssertLessThanOrEqual(BridgeConnectionPolicy.maxConcurrentConnections, 64)
    }

    func testBusyRejectionFrameIsOneBusyErrorLine() throws {
        let frame = BridgeConnectionPolicy.busyRejectionFrame()
        XCTAssertEqual(frame.last, 0x0A)
        XCTAssertEqual(frame.filter { $0 == 0x0A }.count, 1)
        let decoded = try JSONDecoder().decode(BridgeWire.Response<BridgeWire.NoParams>.self,
                                               from: frame.dropLast())
        XCTAssertEqual(decoded.error?.data?.reason, .busy)
    }
}

/// A tiny lock-protected box for cross-thread test state.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}
