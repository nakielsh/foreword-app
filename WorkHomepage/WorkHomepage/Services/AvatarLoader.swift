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

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Returns a 48x48 NSImage for `url`. Falls back to a monogram image
    /// when `url` is nil, the request fails, or the server returns non-2xx.
    ///
    /// Subsequent calls with the same URL return the cached NSImage without
    /// re-fetching. The returned image is always non-nil.
    func image(for url: URL?, login: String) async -> NSImage {
        guard let url else {
            return MonogramRenderer.render(login: login, size: 48)
        }

        let nsURL = url as NSURL
        if let cached = cache.object(forKey: nsURL) {
            return cached
        }

        if let existing = inFlight[nsURL] {
            return await existing.value
        }

        let task = Task<NSImage, Never> { [weak self] in
            await Self.fetchImage(url: url, login: login)
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

    private static func fetchImage(url: URL, login: String) async -> NSImage {
        var request = URLRequest(url: url)
        request.timeoutInterval = AvatarLoader.requestTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
