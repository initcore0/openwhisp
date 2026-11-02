import XCTest
import Darwin
@testable import OpenWhispBridgeKit
@testable import OpenWhispCore

/// A one-connection UNIX-socket server standing in for a wedged / busy app.
final class TestUnixListener {
    let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var conns: [Int32] = []

    /// `onAccept` runs on a background thread with the accepted fd.
    init(onAccept: @escaping (Int32) -> Void) throws {
        path = NSTemporaryDirectory() + "owbt-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                p.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, src, 103) }
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 4) == 0 else {
            throw NSError(domain: "TestUnixListener", code: Int(errno))
        }
        let lfd = listenFD
        Thread.detachNewThread { [weak self] in
            let c = accept(lfd, nil, nil)
            guard c >= 0 else { return }
            self?.track(c)
            onAccept(c)
        }
    }

    private func track(_ fd: Int32) { lock.lock(); conns.append(fd); lock.unlock() }

    func stop() {
        lock.lock(); let cs = conns; conns = []; lock.unlock()
        for c in cs { shutdown(c, SHUT_RDWR) }
        close(listenFD)
        unlink(path)
    }

    deinit { stop() }

    /// Read (and discard) until the peer goes away — an app that takes the
    /// request but never answers.
    static func readForever(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while read(fd, &buf, buf.count) > 0 {}
    }

    /// Read one request line, then write `frame`.
    static func replyOnce(_ fd: Int32, frame: Data) {
        var buf = [UInt8](repeating: 0, count: 4096)
        var got = Data()
        while !got.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            got.append(contentsOf: buf[0..<n])
        }
        frame.withUnsafeBytes { _ = write(fd, $0.baseAddress, frame.count) }
    }
}

/// BridgeClient's bounded connect/write/read: a wedged app must surface as
/// `.timedOut`, never an indefinite hang (BUG_HUNT_2026-07, "BridgeClient has no
/// read/connect timeout").
final class BridgeClientTimeoutTests: XCTestCase {

    func testCallTimesOutWhenTheAppNeverAnswers() throws {
        let listener = try TestUnixListener { TestUnixListener.readForever($0) }
        defer { listener.stop() }
        let client = try BridgeClient(socketPath: listener.path, responseDeadline: { _, _ in 0.3 })

        let done = expectation(description: "status returned")
        var thrown: Error?
        let started = Date()
        DispatchQueue.global().async {
            do {
                _ = try client.call(method: BridgeWire.Method.status.rawValue,
                                    params: BridgeWire.NoParams(),
                                    resultType: BridgeWire.DictateCancelResult.self)
            } catch { thrown = error }
            done.fulfill()
        }
        // Without the deadline the read blocks forever and this wait fails.
        wait(for: [done], timeout: 5)
        guard case .timedOut(let method, let seconds)? = thrown as? BridgeClient.ClientError else {
            return XCTFail("expected .timedOut, got \(String(describing: thrown))")
        }
        XCTAssertEqual(method, "status")
        XCTAssertEqual(seconds, 0.3, accuracy: 0.001)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testDictateDeadlineIsDerivedFromTheRequestTimeout() throws {
        let listener = try TestUnixListener { TestUnixListener.readForever($0) }
        defer { listener.stop() }
        var seen: (String, Int?)?
        let client = try BridgeClient(socketPath: listener.path, responseDeadline: { m, t in
            seen = (m, t); return 0.1
        })
        XCTAssertThrowsError(try client.call(
            method: BridgeWire.Method.dictate.rawValue,
            params: BridgeWire.DictateParams(prompt: "q", timeoutSeconds: 42),
            resultType: BridgeWire.DictateResult.self))
        XCTAssertEqual(seen?.0, "dictate")
        XCTAssertEqual(seen?.1, 42)
    }

    func testAnswerWithinDeadlineSucceeds() throws {
        let frame = Data(#"{"jsonrpc":"2.0","id":1,"result":{"cancelled":true}}"#.utf8 + [0x0A])
        let listener = try TestUnixListener { TestUnixListener.replyOnce($0, frame: frame) }
        defer { listener.stop() }
        let client = try BridgeClient(socketPath: listener.path, responseDeadline: { _, _ in 5 })
        let r = try client.call(method: BridgeWire.Method.dictateCancel.rawValue,
                                params: BridgeWire.NoParams(),
                                resultType: BridgeWire.DictateCancelResult.self)
        XCTAssertTrue(r.cancelled)
    }

    /// The app's over-the-cap rejection frame reads as a clear `busy` error, not
    /// as "app not running".
    func testServerBusyRejectionSurfacesAsBusy() throws {
        let frame = BridgeConnectionPolicy.busyRejectionFrame()
        let listener = try TestUnixListener { TestUnixListener.replyOnce($0, frame: frame) }
        defer { listener.stop() }
        let client = try BridgeClient(socketPath: listener.path)
        XCTAssertThrowsError(try client.handshake(clientName: "test")) { error in
            guard case .domain(let reason, let message, _)? = error as? BridgeClient.ClientError else {
                return XCTFail("expected .domain, got \(error)")
            }
            XCTAssertEqual(reason, .busy)
            XCTAssertTrue(message.contains("too many"))
        }
    }

    func testMissingSocketIsUnreachable() {
        let path = NSTemporaryDirectory() + "owbt-missing-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertThrowsError(try BridgeClient(socketPath: path)) { error in
            guard case .unreachable? = error as? BridgeClient.ClientError else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        }
    }

    // MARK: - Deadline policy

    func testControlVerbsGetAShortDeadline() {
        for m in [BridgeWire.Method.hello, .status, .dictateStop, .dictateCancel] {
            XCTAssertEqual(BridgeTimeouts.responseDeadline(method: m.rawValue, dictateTimeoutSeconds: nil),
                           BridgeTimeouts.controlSeconds, m.rawValue)
        }
    }

    func testDictateDeadlineOutlastsConsentPlusTheAppSideTimeout() {
        for requested in [nil, 1, 60, 120, 300, 10_000] as [Int?] {
            let appSide = BridgeRouter.resolvedTimeoutSeconds(requested)
            let d = BridgeTimeouts.responseDeadline(method: "dictate", dictateTimeoutSeconds: requested)
            XCTAssertGreaterThan(d, BridgeTimeouts.consentWindowSeconds + TimeInterval(appSide),
                                 "requested \(String(describing: requested))")
        }
        // Clamped like the app: an absurd request can't buy an unbounded wait.
        XCTAssertEqual(BridgeTimeouts.responseDeadline(method: "dictate", dictateTimeoutSeconds: 10_000),
                       BridgeTimeouts.responseDeadline(method: "dictate", dictateTimeoutSeconds: 300))
    }

    func testConsentGatedVerbsCoverTheConsentWindow() {
        for m in [BridgeWire.Method.historyList, .refine, .transcribeFile, .syncManifest, .syncPull, .syncPush] {
            XCTAssertGreaterThan(BridgeTimeouts.responseDeadline(method: m.rawValue, dictateTimeoutSeconds: nil),
                                 BridgeTimeouts.consentWindowSeconds, m.rawValue)
        }
        XCTAssertGreaterThan(BridgeTimeouts.responseDeadline(method: "future.verb", dictateTimeoutSeconds: nil),
                             BridgeTimeouts.consentWindowSeconds)
    }
}
