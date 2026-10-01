//
//  JiraConfigTests.swift
//  ForewordTests
//
//  Round-trips JiraConfig set/get for baseURL + email + token, using
//  unique-per-test Keychain accounts and a per-test UserDefaults suite so we
//  never trample a developer's real Jira credentials.
//

import XCTest
@testable import Foreword

final class JiraConfigTests: XCTestCase {

    private var defaultsSuite: String!
    private var defaults: UserDefaults!
    private var baseURLKey: String!
    private var emailKey: String!
    private var tokenKey: String!

    override func setUp() {
        super.setUp()
        defaultsSuite = "JiraConfigTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        baseURLKey = "test.jira.baseURL.\(UUID().uuidString)"
        emailKey = "test.jira.email.\(UUID().uuidString)"
        tokenKey = "test.jira.token.\(UUID().uuidString)"
    }

    override func tearDown() {
        if let defaultsSuite {
            UserDefaults().removePersistentDomain(forName: defaultsSuite)
        }
        KeychainStore.delete(key: emailKey)
        KeychainStore.delete(key: tokenKey)
        super.tearDown()
    }

    // MARK: - Base URL

    func testBaseURLRoundTrip() {
        XCTAssertNil(JiraConfig.getBaseURL(key: baseURLKey, defaults: defaults))
        JiraConfig.setBaseURL("https://acme.atlassian.net", key: baseURLKey, defaults: defaults)
        XCTAssertEqual(JiraConfig.getBaseURL(key: baseURLKey, defaults: defaults), "https://acme.atlassian.net")
    }

    func testBaseURLEmptyClearsValue() {
        JiraConfig.setBaseURL("https://acme.atlassian.net", key: baseURLKey, defaults: defaults)
        JiraConfig.setBaseURL("", key: baseURLKey, defaults: defaults)
        XCTAssertNil(JiraConfig.getBaseURL(key: baseURLKey, defaults: defaults))
    }

    func testBaseURLTrimsWhitespace() {
        JiraConfig.setBaseURL("   https://acme.atlassian.net   ", key: baseURLKey, defaults: defaults)
        XCTAssertEqual(JiraConfig.getBaseURL(key: baseURLKey, defaults: defaults), "https://acme.atlassian.net")
    }

    // MARK: - Email

    func testEmailRoundTrip() {
        XCTAssertNil(JiraConfig.getEmail(key: emailKey))
        JiraConfig.setEmail("dev@example.com", key: emailKey)
        XCTAssertEqual(JiraConfig.getEmail(key: emailKey), "dev@example.com")
    }

    func testEmailEmptyClearsValue() {
        JiraConfig.setEmail("dev@example.com", key: emailKey)
        JiraConfig.setEmail("", key: emailKey)
        XCTAssertNil(JiraConfig.getEmail(key: emailKey))
    }

    // MARK: - Token

    func testTokenRoundTrip() {
        XCTAssertNil(JiraConfig.getToken(key: tokenKey))
        JiraConfig.setToken("super-secret-token", key: tokenKey)
        XCTAssertEqual(JiraConfig.getToken(key: tokenKey), "super-secret-token")
    }

    func testTokenEmptyClearsValue() {
        JiraConfig.setToken("super-secret-token", key: tokenKey)
        JiraConfig.setToken("", key: tokenKey)
        XCTAssertNil(JiraConfig.getToken(key: tokenKey))
    }

    func testTokenReplacedWhenSetTwice() {
        JiraConfig.setToken("first", key: tokenKey)
        JiraConfig.setToken("second", key: tokenKey)
        XCTAssertEqual(JiraConfig.getToken(key: tokenKey), "second")
    }
}
