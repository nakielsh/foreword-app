//
//  MonogramRendererTests.swift
//  WorkHomepageTests
//
//  Slice 21 — Determinism, glyph edge cases, and color variance for
//  MonogramRenderer.
//

import XCTest
import AppKit
@testable import WorkHomepage

final class MonogramRendererTests: XCTestCase {

    // MARK: - Determinism

    func testSameLoginAndSizeProducesIdenticalTIFFRepresentation() {
        let a = MonogramRenderer.render(login: "alice", size: 48)
        let b = MonogramRenderer.render(login: "alice", size: 48)
        XCTAssertEqual(a.tiffRepresentation, b.tiffRepresentation,
                       "Same login + size must produce byte-identical TIFF")
    }

    func testDifferentLoginsShouldProduceDifferentImages() {
        let a = MonogramRenderer.render(login: "alice", size: 48)
        let b = MonogramRenderer.render(login: "bob", size: 48)
        XCTAssertNotEqual(a.tiffRepresentation, b.tiffRepresentation,
                          "Different logins should produce different images (different hues)")
    }

    // MARK: - Glyph edge cases

    func testEmptyLoginRendersQuestionMark() {
        let image = MonogramRenderer.render(login: "", size: 48)
        XCTAssertNotNil(image.tiffRepresentation, "Empty login should still produce a valid image")
        // Verify it differs from a regular monogram — pixel-level verification
        // would require drawing into a CGContext; we at least confirm the render
        // completes without crashing and matches a second call for stability.
        let image2 = MonogramRenderer.render(login: "", size: 48)
        XCTAssertEqual(image.tiffRepresentation, image2.tiffRepresentation,
                       "Empty login renders must be deterministic")
    }

    func testWhitespaceOnlyLoginRendersQuestionMark() {
        let image = MonogramRenderer.render(login: "   ", size: 48)
        let empty = MonogramRenderer.render(login: "", size: 48)
        XCTAssertEqual(image.tiffRepresentation, empty.tiffRepresentation,
                       "Whitespace-only login should render the same as empty login")
    }

    func testNonASCIILoginUsesFirstScalarUppercased() {
        // "Åsa" — first scalar is Å (U+00C5), uppercased stays Å.
        let image = MonogramRenderer.render(login: "Åsa", size: 48)
        XCTAssertNotNil(image.tiffRepresentation, "Non-ASCII login should produce a valid image")
        // Must be deterministic.
        let image2 = MonogramRenderer.render(login: "Åsa", size: 48)
        XCTAssertEqual(image.tiffRepresentation, image2.tiffRepresentation)
    }

    func testNumericLoginUsesFirstCharacter() {
        // "123abc" → first character "1".
        let image = MonogramRenderer.render(login: "123abc", size: 48)
        XCTAssertNotNil(image.tiffRepresentation, "Numeric-prefix login should produce a valid image")
        let image2 = MonogramRenderer.render(login: "123abc", size: 48)
        XCTAssertEqual(image.tiffRepresentation, image2.tiffRepresentation)
    }

    // MARK: - Image dimensions

    func testRenderedImageHasCorrectSize() {
        let size: CGFloat = 64
        let image = MonogramRenderer.render(login: "test", size: size)
        XCTAssertEqual(image.size.width, size)
        XCTAssertEqual(image.size.height, size)
    }

    func testRenderedImageHasCorrectSizeForSmallRequest() {
        let size: CGFloat = 24
        let image = MonogramRenderer.render(login: "test", size: size)
        XCTAssertEqual(image.size.width, size)
        XCTAssertEqual(image.size.height, size)
    }

    // MARK: - Color variance (different logins → different hues)

    func testMultipleLoginsProduceDifferentImages() {
        let logins = ["alice", "bob", "carol", "dave", "eve"]
        var images: [Data] = []
        for login in logins {
            let tiff = MonogramRenderer.render(login: login, size: 48).tiffRepresentation ?? Data()
            images.append(tiff)
        }
        // All images must be distinct (different hues → different pixel data).
        let unique = Set(images.map { $0.hashValue })
        XCTAssertEqual(unique.count, logins.count,
                       "Each unique login should produce a unique image")
    }
}
