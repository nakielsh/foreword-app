//
//  AvatarLoader.swift
//  WorkHomepage
//
//  Slice 21 — Async image loader with in-memory NSCache and monogram fallback.
//
//  Public API:
//    AvatarLoader.shared.image(for:login:) async -> NSImage
//
//  - NSCache<NSURL, NSImage> with countLimit 200 prevents unbounded growth.
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

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 200
        return c
    }()

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

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
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
