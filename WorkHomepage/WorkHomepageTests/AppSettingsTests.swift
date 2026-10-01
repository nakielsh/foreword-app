//
//  AppSettingsTests.swift
//  WorkHomepageTests
//
//  Concurrency cap default + clamp behavior, project key prefixes round-trip.
//  Each test uses a fresh UserDefaults suite to avoid touching the developer's
//  real settings.
//

import XCTest
@testable import WorkHomepage

final class AppSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - Concurrency cap

    func testConcurrencyCapDefaultsToThreeWhenAbsent() {
        XCTAssertEqual(AppSettings.concurrencyCap(defaults: defaults), 3)
    }

    func testConcurrencyCapClampsBelowMin() {
        AppSettings.setConcurrencyCap(0, defaults: defaults)
        XCTAssertEqual(AppSettings.concurrencyCap(defaults: defaults), AppSettings.concurrencyCapMin)

        AppSettings.setConcurrencyCap(-50, defaults: defaults)
        XCTAssertEqual(AppSettings.concurrencyCap(defaults: defaults), AppSettings.concurrencyCapMin)
    }

    func testConcurrencyCapClampsAboveMax() {
        AppSettings.setConcurrencyCap(99, defaults: defaults)
        XCTAssertEqual(AppSettings.concurrencyCap(defaults: defaults), AppSettings.concurrencyCapMax)
    }

    func testConcurrencyCapRoundTripInRange() {
        for value in AppSettings.concurrencyCapMin...AppSettings.concurrencyCapMax {
            AppSettings.setConcurrencyCap(value, defaults: defaults)
            XCTAssertEqual(AppSettings.concurrencyCap(defaults: defaults), value)
        }
    }

    // MARK: - Project key prefixes

    func testProjectKeyPrefixesDefaultEmpty() {
        XCTAssertEqual(AppSettings.projectKeyPrefixes(defaults: defaults), [])
    }

    func testProjectKeyPrefixesRoundTrip() {
        AppSettings.setProjectKeyPrefixes(["PROJ", "ABC", "XYZ"], defaults: defaults)
        XCTAssertEqual(AppSettings.projectKeyPrefixes(defaults: defaults), ["PROJ", "ABC", "XYZ"])
    }

    func testProjectKeyPrefixesTrimsAndDropsEmpty() {
        AppSettings.setProjectKeyPrefixes(["  PROJ  ", "", " ", "ABC"], defaults: defaults)
        XCTAssertEqual(AppSettings.projectKeyPrefixes(defaults: defaults), ["PROJ", "ABC"])
    }

    func testProjectKeyPrefixesEmptyArrayPersists() {
        AppSettings.setProjectKeyPrefixes(["PROJ"], defaults: defaults)
        AppSettings.setProjectKeyPrefixes([], defaults: defaults)
        XCTAssertEqual(AppSettings.projectKeyPrefixes(defaults: defaults), [])
    }
}
