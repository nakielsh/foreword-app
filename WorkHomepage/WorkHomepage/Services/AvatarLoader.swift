//
//  AvatarLoader.swift
//  WorkHomepage
//
//  Slice 21 — Async image loader with in-memory NSCache and monogram fallback.
//
//  Public API:
//    AvatarLoader.shared.image(for:login:) async -> NSImage
//
//  - NSCache<NSURL, NSImage> bounded by both count (200 entries) and total
//    cost (32 MB) so a multi-day session with many high-res avatars cannot
//    accumulate hundreds of MB of decoded image data.
//  - Concurrent requests for the same URL are coalesced into a single
//    in-flight Task; subsequent callers await the same NSImage rather than
//    each issuing their own GET.
//  - Nil URL, non-2xx HTTP, or network error → MonogramRenderer fallback.
//  - URLSession.shared.data(from:) respects cooperative Task cancellation.
//  - Cache key is the URL itself; monogram results are NOT cached (they are
//    cheap to regenerate and have no meaningful URL key).
//

import AppKit
import Foundation

@MainActor
final class AvatarLoader {

    // MARK: - Singleton

    static let shared = AvatarLoader()

    // MARK: - Cache

    /// Per-request timeout for avatar GETs. Avatars are tiny; a stuck socket
    /// during sleep/VPN reconnect must not pin a refresh.
    private static let requestTimeout: TimeInterval = 10
    /// Cap decoded NSImage RAM usage. NSCache evicts least-recently-used when
    /// either bound is exceeded.
    private static let cacheCostBytes = 32 * 1024 * 1024

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 200
        c.totalCostLimit = AvatarLoader.cacheCostBytes
        return c
    }()

    /// In-flight Task per URL so N concurrent callers for the same avatar
    /// share one network fetch instead of starting N redundant requests.
    private var inFlight: [NSURL: Task<NSImage, Never>] = [:]

    /// URLSession used for image GETs. Production wires `URLSession.shared`;
    /// tests inject an `URLSessionConfiguration.ephemeral` session that
    /// routes through `URLProtocolStub`. Stored on the instance so the
    /// singleton stays unchanged across test runs.
    private let session: URLSession

    // MARK: - Init

    private init() {
        self.session = URLSession.shared
    }

    /// Test-only initialiser. Lets a test construct a fresh `AvatarLoader`
    /// with an injected URLSession (typically `URLProtocolStub`-backed)
    /// and exercise the real type rather than a hand-rolled lookalike.
    init(session: URLSession) {
        self.session = session
    }

    // MARK: - Public API

    /// GitHub avatar size (in CSS px) we ask the CDN to serve. The UI renders
    /// at 48pt, so 96px covers up-to-2x Retina without paying for the default
    /// 460-ish-px source. Capping the size also caps decoded NSImage RAM —
    /// 96×96 ≈ 36KB after RGBA expansion vs. 800KB+ for an unrequested
    /// avatar. Cache cost stays predictable across a multi-day session.
    private static let githubAvatarPixelSize = 96

    /// Returns a 48x48 NSImage for `url`. Falls back to a monogram image
    /// when `url` is nil, the request fails, or the server returns non-2xx.
    ///
    /// Subsequent calls with the same URL return the cached NSImage without
    /// re-fetching. The returned image is always non-nil.
    func image(for url: URL?, login: String) async -> NSImage {
        guard let url else {
            return MonogramRenderer.render(login: login, size: 48)
        }

        let sizedURL = Self.appendingSizeParam(to: url, size: Self.githubAvatarPixelSize)
        let nsURL = sizedURL as NSURL
        if let cached = cache.object(forKey: nsURL) {
            return cached
        }

        if let existing = inFlight[nsURL] {
            return await existing.value
        }

        let session = self.session
        let task = Task<NSImage, Never> {
            await Self.fetchImage(session: session, url: sizedURL, login: login)
        }
        inFlight[nsURL] = task
        let image = await task.value
        inFlight[nsURL] = nil
        // Cache cost = pixels × 4 bytes (RGBA). Falls back to a fixed estimate
        // when size is unknown (CGImage backed by EXIF orientation, etc.).
        let cost: Int
        if let rep = image.representations.first {
            cost = rep.pixelsWide * rep.pixelsHigh * 4
        } else {
            cost = 48 * 48 * 4
        }
        cache.setObject(image, forKey: nsURL, cost: cost)
        return image
    }

    /// Returns `url` with `s=<size>` merged into its query. If a different
    /// `s` value is already present we overwrite it; any other query items
    /// are preserved. Falls back to the original URL on parse failure so a
    /// bad URL still returns *something* parseable to URLSession (which will
    /// then fail and trigger the monogram fallback).
    static func appendingSizeParam(to url: URL, size: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "s" }
        items.append(URLQueryItem(name: "s", value: String(size)))
        components.queryItems = items
        return components.url ?? url
    }

    private static func fetchImage(session: URLSession, url: URL, login: String) async -> NSImage {
        var request = URLRequest(url: url)
        request.timeoutInterval = AvatarLoader.requestTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return MonogramRenderer.render(login: login, size: 48)
            }
            guard let image = NSImage(data: data) else {
                return MonogramRenderer.render(login: login, size: 48)
            }
            return image
        } catch {
            return MonogramRenderer.render(login: login, size: 48)
        }
    }
}
