//
//  AppSettingsTests.swift
//  ForewordTests
//
//  Concurrency cap default + clamp behavior, project key prefixes round-trip.
//  Each test uses a fresh UserDefaults suite to avoid touching the developer's
//  real settings.
//

import XCTest
@testable import Foreword

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

    // MARK: - Extra environment variables

    func testExtraEnvDefaultsToEmpty() {
        assertThat(AppSettings.extraEnvKeys(defaults: defaults)).isEmpty()
        assertThat(AppSettings.extraEnvPrefixes(defaults: defaults)).isEmpty()
    }

    func testExtraEnvRoundTripsAndDropsBlanks() {
        AppSettings.setExtraEnvKeys(["  REPO_USER ", "", "NPM_TOKEN"], defaults: defaults)
        AppSettings.setExtraEnvPrefixes(["ARTIFACTORY_", " "], defaults: defaults)

        assertThat(AppSettings.extraEnvKeys(defaults: defaults)).containsExactly(["REPO_USER", "NPM_TOKEN"])
        assertThat(AppSettings.extraEnvPrefixes(defaults: defaults)).containsExactly(["ARTIFACTORY_"])
    }

    func testParsesExtraEnvListWithStarMarkingPrefixes() {
        let parsed = AppSettings.parseExtraEnvList(" REPO_USER, ARTIFACTORY_* ,, NPM_TOKEN,*")

        assertThat(parsed.keys).containsExactly(["REPO_USER", "NPM_TOKEN"])
        assertThat(parsed.prefixes).containsExactly(["ARTIFACTORY_"])
    }

    func testFormatsExtraEnvListForTheSettingsField() {
        let text = AppSettings.formatExtraEnvList(keys: ["REPO_USER"], prefixes: ["ARTIFACTORY_"])

        assertThat(text).isEqualTo("REPO_USER, ARTIFACTORY_*")
        let parsed = AppSettings.parseExtraEnvList(text)
        assertThat(parsed.keys).containsExactly(["REPO_USER"])
        assertThat(parsed.prefixes).containsExactly(["ARTIFACTORY_"])
    }
}
