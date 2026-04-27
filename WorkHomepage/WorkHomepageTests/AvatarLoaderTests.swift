//
//  AvatarLoaderTests.swift
//  WorkHomepageTests
//
//  Slice 21 — Cache-hit, nil-URL fallback, non-2xx fallback, and cancellation
//  tests for the real `AvatarLoader`. Earlier slices tested an
//  `AvatarLoaderSUT` reimplementation; we now drive the production type
//  through its `init(session:)` test seam, with `URLSession` wired through
//  the unified `URLProtocolStub`.
//

import XCTest
import AppKit
@testable import WorkHomepage

@MainActor
final class AvatarLoaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Nil URL → monogram

    func testNilURLReturnsMonogram() async {
        // Singleton is fine here — no network involved when URL is nil.
        let result = await AvatarLoader.shared.image(for: nil, login: "alice")
        let expected = MonogramRenderer.render(login: "alice", size: 48)
        XCTAssertEqual(result.tiffRepresentation, expected.tiffRepresentation,
                       "Nil URL must return the matching monogram")
    }

    // MARK: - Non-2xx HTTP → monogram

    func testNon2xxHTTPReturnsMonogram() async {
        URLProtocolStub.respond { req in
            .success(URLProtocolStub.http(404, url: req.url!), Data())
        }
        let loader = AvatarLoader(session: URLProtocolStub.makeSession())
        let url = URL(string: "https://example.com/avatar.png")!
        let result = await loader.image(for: url, login: "bob")
        let expected = MonogramRenderer.render(login: "bob", size: 48)
        XCTAssertEqual(result.tiffRepresentation, expected.tiffRepresentation,
                       "Non-2xx must fall back to monogram")
    }

    // MARK: - Network error → monogram

    func testNetworkErrorReturnsMonogram() async {
        URLProtocolStub.failWith(URLError(.notConnectedToInternet))
        let loader = AvatarLoader(session: URLProtocolStub.makeSession())
        let url = URL(string: "https://example.com/avatar.png")!
        let result = await loader.image(for: url, login: "carol")
        let expected = MonogramRenderer.render(login: "carol", size: 48)
        XCTAssertEqual(result.tiffRepresentation, expected.tiffRepresentation,
                       "Network error must fall back to monogram")
    }

    // MARK: - Successful fetch

    func testSuccessfulFetchReturnsRealImage() async {
        URLProtocolStub.respond { req in
            .success(URLProtocolStub.http(200, url: req.url!), Self.minimal1x1PNG())
        }
        let loader = AvatarLoader(session: URLProtocolStub.makeSession())
        let url = URL(string: "https://example.com/cached.png")!
        let result = await loader.image(for: url, login: "dave")
        // Successful fetch returns the decoded NSImage, NOT a monogram —
        // distinguishable by tiffRepresentation byte-equality.
        let monogram = MonogramRenderer.render(login: "dave", size: 48)
        XCTAssertNotEqual(result.tiffRepresentation, monogram.tiffRepresentation,
                          "Successful fetch must NOT fall back to monogram")
    }

    // MARK: - Cache hit returns same NSImage reference

    func testCacheHitReturnsSameReference() async {
        URLProtocolStub.respond { req in
            .success(URLProtocolStub.http(200, url: req.url!), Self.minimal1x1PNG())
        }
        let loader = AvatarLoader(session: URLProtocolStub.makeSession())
        let url = URL(string: "https://example.com/cached2.png")!
        let first = await loader.image(for: url, login: "eve")
        let second = await loader.image(for: url, login: "eve")
        XCTAssertTrue(first === second,
                      "Second call with the same URL must return the cached NSImage reference")
    }

    // MARK: - Cancellation

    func testCancellationDoesNotCrash() async {
        URLProtocolStub.respond { req in
            .success(URLProtocolStub.http(200, url: req.url!), Self.minimal1x1PNG())
        }
        let loader = AvatarLoader(session: URLProtocolStub.makeSession())
        let url = URL(string: "https://example.com/cancel-test.png")!
        let task = Task { @MainActor in
            _ = await loader.image(for: url, login: "frank")
        }
        task.cancel()
        // Awaiting fully-exits the task either via completion or cooperative
        // cancellation; we only care that no crash fires.
        await task.value
    }

    // MARK: - Helpers

    /// Minimal valid 1×1 PNG (67 bytes).
    private static func minimal1x1PNG() -> Data {
        // swiftlint:disable:next line_length
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64)!
    }
}
