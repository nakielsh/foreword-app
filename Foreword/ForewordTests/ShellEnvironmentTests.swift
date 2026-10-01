//
//  ShellEnvironmentTests.swift
//  ForewordTests
//
//  Covers the `env` output parser. The actual shell capture exec'd against
//  the user's real `$SHELL` isn't unit-tested here — it has to run against
//  a live machine and would either depend on the test runner's env or be
//  flaky. The parser is the part where bugs would silently drop variables
//  the user expected to inherit.
//

import XCTest
@testable import Foreword

final class ShellEnvironmentTests: XCTestCase {

    func testParsesSimpleKeyValueLines() {
        let raw = """
        HOME=/Users/test
        USER=test
        PATH=/usr/local/bin:/usr/bin
        """
        let parsed = ShellEnvironment.parse(raw)
        XCTAssertEqual(parsed["HOME"], "/Users/test")
        XCTAssertEqual(parsed["USER"], "test")
        XCTAssertEqual(parsed["PATH"], "/usr/local/bin:/usr/bin")
    }

    func testParsesEmptyValues() {
        let raw = "EMPTY=\nKEEP=value"
        let parsed = ShellEnvironment.parse(raw)
        XCTAssertEqual(parsed["EMPTY"], "")
        XCTAssertEqual(parsed["KEEP"], "value")
    }

    func testParsesUnderscoreAndDigitKeys() {
        let raw = """
        REPO_USER=alice
        REPO_TOKEN=secret
        JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home
        _COMP_OPTIONS=foo
        """
        let parsed = ShellEnvironment.parse(raw)
        XCTAssertEqual(parsed["REPO_USER"], "alice")
        XCTAssertEqual(parsed["REPO_TOKEN"], "secret")
        XCTAssertEqual(parsed["JAVA_HOME"], "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home")
        XCTAssertEqual(parsed["_COMP_OPTIONS"], "foo")
    }

    func testIgnoresLinesThatDontLookLikeKeyValue() {
        // Shell can write banners, prompts, ls totals before `env` runs.
        // Those lines must not pollute the parsed map (and must not crash).
        let raw = """
        Last login: Mon May 10
        total 256
        REAL_KEY=value
        """
        let parsed = ShellEnvironment.parse(raw)
        XCTAssertEqual(parsed["REAL_KEY"], "value")
        XCTAssertNil(parsed["Last login"])
        XCTAssertNil(parsed["total 256"])
    }

    func testValuesContainingEqualsKeepFullSuffix() {
        // Things like `LS_COLORS=di=1;31:fi=0` are common.
        let raw = "LS_COLORS=di=1;31:fi=0"
        let parsed = ShellEnvironment.parse(raw)
        XCTAssertEqual(parsed["LS_COLORS"], "di=1;31:fi=0")
    }

    func testMultilineValuesAreFoldedIntoPriorKey() {
        // `env` doesn't quote newlines in values, so a multi-line value
        // appears as a continuation. The parser folds it back rather than
        // dropping the suffix or treating the next line as a new key.
        let raw = """
        FIRST=alpha
        MULTI=line1
        line2
        line3
        AFTER=beta
        """
        let parsed = ShellEnvironment.parse(raw)
        XCTAssertEqual(parsed["FIRST"], "alpha")
        XCTAssertEqual(parsed["MULTI"], "line1\nline2\nline3")
        XCTAssertEqual(parsed["AFTER"], "beta")
    }

    func testRejectsKeysStartingWithDigit() {
        // POSIX env-var names don't start with digits. A line like
        // `2024-01-01 07:00:00` shouldn't parse as a key.
        let raw = "2BAD=nope\nOK=yes"
        let parsed = ShellEnvironment.parse(raw)
        XCTAssertNil(parsed["2BAD"])
        XCTAssertEqual(parsed["OK"], "yes")
    }

    func testEmptyOutputProducesEmptyMap() {
        XCTAssertTrue(ShellEnvironment.parse("").isEmpty)
    }

    func testFiltersEmployerSpecificKeysByDefault() {
        let env = [
            "JAVA_HOME": "/jdk",
            "GRADLE_USER_HOME": "/gradle",
            "REPO_USER": "alice",
            "ARTIFACTORY_TOKEN": "tok",
            "ANTHROPIC_API_KEY": "should-be-dropped",
            "AWS_SECRET_ACCESS_KEY": "should-be-dropped"
        ]

        let filtered = ShellEnvironment.filter(env)

        assertThat(filtered["JAVA_HOME"]).isEqualTo("/jdk")
        assertThat(filtered["GRADLE_USER_HOME"]).isEqualTo("/gradle")
        assertThat(filtered["REPO_USER"]).isNil()
        assertThat(filtered["ARTIFACTORY_TOKEN"]).isNil()
        assertThat(filtered["ANTHROPIC_API_KEY"]).isNil()
        assertThat(filtered["AWS_SECRET_ACCESS_KEY"]).isNil()
    }

    func testForwardsUserConfiguredExtraKeysAndPrefixes() {
        let env = [
            "REPO_USER": "alice",
            "ARTIFACTORY_USER": "alice",
            "ARTIFACTORY_TOKEN": "tok",
            "ANTHROPIC_API_KEY": "should-be-dropped"
        ]

        let filtered = ShellEnvironment.filter(env, extraKeys: ["REPO_USER"], extraPrefixes: ["ARTIFACTORY_"])

        assertThat(filtered["REPO_USER"]).isEqualTo("alice")
        assertThat(filtered["ARTIFACTORY_USER"]).isEqualTo("alice")
        assertThat(filtered["ARTIFACTORY_TOKEN"]).isEqualTo("tok")
        assertThat(filtered["ANTHROPIC_API_KEY"]).isNil()
    }
}
