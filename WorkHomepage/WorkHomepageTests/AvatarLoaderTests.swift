//
//  AvatarLoaderTests.swift
//  WorkHomepageTests
//
//  Slice 21 — Cache-hit, nil-URL fallback, non-2xx fallback, and cancellation
//  tests for AvatarLoader.
//
//  Uses a private URLProtocol stub (AvatarStubURLProtocol) to intercept
//  network requests without hitting the network, matching the convention used
//  by JiraCacheTests (per-file stub named after the feature under test).
//

import XCTest
import AppKit
@testable import WorkHomepage

// MARK: - AvatarLoaderTests

final class AvatarLoaderTests: XCTestCase {

    // MARK: - Nil URL → monogram

    @MainActor
    func testNilURLReturnsMono() async {
        let result = await AvatarLoader.shared.image(for: nil, login: "alice")
        let expected = MonogramRenderer.render(login: "alice", size: 48)
        XCTAssertEqual(
            result.tiffRepresentation,
            expected.tiffRepresentation,
            "Nil URL should return monogram matching MonogramRenderer.render(login:size:)"
        )
    }

    // MARK: - Non-2xx HTTP → monogram (via AvatarLoaderSUT)

    @MainActor
    func testNon2xxHTTPReturnsMono() async {
        let sut = AvatarLoaderSUT(statusCode: 404, data: Data(), simulateError: false)
        let url = URL(string: "https://example.com/avatar.png")!
        let result = await sut.image(for: url, login: "bob")
        let expected = MonogramRenderer.render(login: "bob", size: 48)
        XCTAssertEqual(
            result.tiffRepresentation,
            expected.tiffRepresentation,
            "Non-2xx response should fall back to monogram"
        )
    }

    // MARK: - Network error → monogram

    @MainActor
    func testNetworkErrorReturnsMono() async {
        let sut = AvatarLoaderSUT(statusCode: 200, data: Data(), simulateError: true)
        let url = URL(string: "https://example.com/avatar.png")!
        let result = await sut.image(for: url, login: "carol")
        let expected = MonogramRenderer.render(login: "carol", size: 48)
        XCTAssertEqual(
            result.tiffRepresentation,
            expected.tiffRepresentation,
            "Network error should fall back to monogram"
        )
    }

    // MARK: - Cache hit returns same NSImage reference

    @MainActor
    func testCacheHitReturnsSameReference() async {
        let sut = AvatarLoaderSUT(statusCode: 200, data: minimal1x1PNG(), simulateError: false)
        let url = URL(string: "https://example.com/cached.png")!
        let first = await sut.image(for: url, login: "dave")
        let second = await sut.image(for: url, login: "dave")
        XCTAssertTrue(first === second,
                      "Second call with same URL should return the cached NSImage reference")
    }

    // MARK: - Cancellation does not crash

    @MainActor
    func testCancellationDoesNotCrash() async {
        let sut = AvatarLoaderSUT(statusCode: 200, data: minimal1x1PNG(), simulateError: false)
        let url = URL(string: "https://example.com/cancel-test.png")!
        let task = Task { @MainActor in
            _ = await sut.image(for: url, login: "eve")
        }
        task.cancel()
        // Awaiting the value ensures the task fully exits (either completes or
        // propagates cancellation) without crashing.
        await task.value
    }

    // MARK: - Helpers

    /// Minimal valid 1×1 PNG (67 bytes).
    private func minimal1x1PNG() -> Data {
        // swiftlint:disable:next line_length
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64)!
    }
}

// MARK: - AvatarLoaderSUT

/// Test-only loader that mirrors AvatarLoader's logic but uses an injected
/// URLSession built from AvatarStubURLProtocol. Avoids touching URLSession.shared
/// or the singleton's private cache — tests are fully isolated.
@MainActor
final class AvatarLoaderSUT {

    private let session: URLSession
    private let cache = NSCache<NSURL, NSImage>()

    init(statusCode: Int, data: Data, simulateError: Bool) {
        AvatarStubURLProtocol.responseStatusCode = statusCode
        AvatarStubURLProtocol.responseData = data
        AvatarStubURLProtocol.simulateError = simulateError
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvatarStubURLProtocol.self]
        session = URLSession(configuration: config)
        cache.countLimit = 200
    }

    func image(for url: URL?, login: String) async -> NSImage {
        guard let url else {
            return MonogramRenderer.render(login: login, size: 48)
        }
        let nsURL = url as NSURL
        if let cached = cache.object(forKey: nsURL) {
            return cached
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return MonogramRenderer.render(login: login, size: 48)
            }
            guard let image = NSImage(data: data) else {
                return MonogramRenderer.render(login: login, size: 48)
            }
            cache.setObject(image, forKey: nsURL)
            return image
        } catch {
            return MonogramRenderer.render(login: login, size: 48)
        }
    }
}

// MARK: - AvatarStubURLProtocol

/// Per-file URLProtocol stub. Uses static state set per-test by AvatarLoaderSUT,
/// following the same pattern as JiraCacheStubURLProtocol (JiraCacheTests.swift).
final class AvatarStubURLProtocol: URLProtocol {

    static var responseData: Data = Data()
    static var responseStatusCode: Int = 200
    static var simulateError: Bool = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if AvatarStubURLProtocol.simulateError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: AvatarStubURLProtocol.responseStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: AvatarStubURLProtocol.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
