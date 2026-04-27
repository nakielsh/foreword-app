//
//  AppearanceTests.swift
//  WorkHomepageTests
//
//  Slice 19 — Appearance enum + AppSettings.appearance round-trip.
//  Exercises the three cases, default, and UserDefaults isolation.
//

import XCTest
import SwiftUI
@testable import WorkHomepage

final class AppearanceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppearanceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Appearance enum

    func testAllCasesCount() {
        XCTAssertEqual(Appearance.allCases.count, 3)
    }

    func testLabelValues() {
        XCTAssertEqual(Appearance.light.label, "Light")
        XCTAssertEqual(Appearance.dark.label, "Dark")
        XCTAssertEqual(Appearance.system.label, "System")
    }

    func testColorSchemeMapping() {
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
        XCTAssertNil(Appearance.system.colorScheme)
    }

    // testIdentifiable + testRawValueRoundTrip removed — they round-tripped
    // a String enum through itself, effectively testing the compiler. The
    // remaining cases (`testAllCasesCount`, `testColorSchemeMapping`,
    // `testLabelValues`) cover the load-bearing surface.

    // MARK: - AppSettings.appearance UserDefaults round-trip

    func testDefaultsToSystemWhenAbsent() {
        XCTAssertEqual(AppSettings.appearance(defaults: defaults), .system)
    }

    func testRoundTripLight() {
        AppSettings.setAppearance(.light, defaults: defaults)
        XCTAssertEqual(AppSettings.appearance(defaults: defaults), .light)
    }

    func testRoundTripDark() {
        AppSettings.setAppearance(.dark, defaults: defaults)
        XCTAssertEqual(AppSettings.appearance(defaults: defaults), .dark)
    }

    func testRoundTripSystem() {
        // Write light first, then overwrite with system.
        AppSettings.setAppearance(.light, defaults: defaults)
        AppSettings.setAppearance(.system, defaults: defaults)
        XCTAssertEqual(AppSettings.appearance(defaults: defaults), .system)
    }

    func testUnknownRawValueFallsBackToSystem() {
        defaults.set("bogus", forKey: AppSettings.appearanceKey)
        XCTAssertEqual(AppSettings.appearance(defaults: defaults), .system)
    }

    func testIsolatedFromStandardDefaults() {
        // Writing to the isolated suite must not affect a fresh isolated suite.
        AppSettings.setAppearance(.dark, defaults: defaults)
        let otherSuiteName = "AppearanceTests-other-\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuiteName)!
        defer { UserDefaults().removePersistentDomain(forName: otherSuiteName) }
        XCTAssertEqual(AppSettings.appearance(defaults: otherDefaults), .system)
    }
}
