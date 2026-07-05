import XCTest
@testable import CodeIsland

/// #240 — per-host cwd allow-list for remote sessions. On a shared remote
/// account every user's hooks reach every connected client; the filter scopes
/// the panel to the configured working directories.
final class RemoteCwdFilterTests: XCTestCase {

    // MARK: remoteEventPassesCwdFilter

    func testEmptyFilterAllowsEverything() {
        XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(cwd: "/anyone/anywhere", filterCSV: ""))
        XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(cwd: nil, filterCSV: ""))
        // Whitespace/commas-only filter is effectively empty — must not drop everything.
        XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(cwd: "/x", filterCSV: " , , "))
        XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(cwd: nil, filterCSV: " , "))
    }

    func testMatchingCwdPasses() {
        XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(
            cwd: "/home/me/projects/api",
            filterCSV: "/home/me/projects"
        ))
        XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(
            cwd: "/srv/my-work/repo",
            filterCSV: "/home/me/projects, /srv/my-work"
        ))
    }

    func testNonMatchingCwdIsDropped() {
        XCTAssertFalse(HookServer.remoteEventPassesCwdFilter(
            cwd: "/home/colleague/projects/api",
            filterCSV: "/home/me/projects"
        ))
    }

    func testMissingCwdIsDroppedWhenFilterIsActive() {
        // Events without a cwd can't be attributed on a shared account — drop them.
        XCTAssertFalse(HookServer.remoteEventPassesCwdFilter(cwd: nil, filterCSV: "/home/me"))
        XCTAssertFalse(HookServer.remoteEventPassesCwdFilter(cwd: "", filterCSV: "/home/me"))
    }

    func testEntriesAreTrimmed() {
        XCTAssertTrue(HookServer.remoteEventPassesCwdFilter(
            cwd: "/data/work/x",
            filterCSV: " /data/work , /other "
        ))
    }

    // MARK: RemoteHost model compatibility

    func testHostsPersistedBeforeCwdFilterDecodeWithEmptyFilter() throws {
        let legacy = """
        {"id":"h1","name":"box","host":"example.com","user":"me",
         "identityFile":"","autoConnect":false}
        """
        let host = try JSONDecoder().decode(RemoteHost.self, from: Data(legacy.utf8))
        XCTAssertEqual(host.cwdFilter, "")
        XCTAssertEqual(host.authSocket, "")
    }

    func testCwdFilterRoundTripsThroughCodable() throws {
        var host = RemoteHost(name: "box", host: "example.com")
        host.cwdFilter = "/home/me/projects"
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: data)
        XCTAssertEqual(decoded.cwdFilter, "/home/me/projects")
    }
}
