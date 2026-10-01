//
//  Assertions.swift
//  ForewordTests
//
//  Single source of the project's AssertJ-style fluent shim. Earlier slices
//  re-implemented this in three places (`ReviewOrchestratorConcurrencyTests`,
//  `IntelliJLauncherTests`, `WorktreeManagerDiskUsageTests`); the per-file
//  copies have all been removed in favour of these definitions.
//
//  Failures are routed through `XCTFail` so Xcode highlights the right line.
//
//  Coverage: the assertions actually used across the suite (`isTrue`,
//  `isFalse`, `isEqualTo`, `isNotEqualTo`, `isNil`, `isNotNil`, `isEmpty`,
//  `hasSize`, `containsExactly`, `contains`, `doesNotContain`, `allEqualTo`,
//  `containsString`, `isLessThan`, `isLessThanOrEqualTo`, `isGreaterThan`,
//  `isGreaterThanOrEqualTo`).
//

import XCTest

// MARK: - Generic value assertion

struct ValueAssertion<T> {
    let value: T
    let file: StaticString
    let line: UInt
}

// MARK: - Array assertion

struct ArrayAssertion<Element> {
    let actual: [Element]
    let file: StaticString
    let line: UInt
}

// MARK: - Entry points

func assertThat<T>(
    _ value: T,
    file: StaticString = #filePath,
    line: UInt = #line
) -> ValueAssertion<T> {
    ValueAssertion(value: value, file: file, line: line)
}

func assertThat<T>(
    _ value: [T],
    file: StaticString = #filePath,
    line: UInt = #line
) -> ArrayAssertion<T> {
    ArrayAssertion(actual: value, file: file, line: line)
}

// MARK: - Bool

extension ValueAssertion where T == Bool {
    func isTrue() {
        if !value {
            XCTFail("expected true, got false", file: file, line: line)
        }
    }

    func isFalse() {
        if value {
            XCTFail("expected false, got true", file: file, line: line)
        }
    }
}

// MARK: - Equatable

extension ValueAssertion where T: Equatable {
    func isEqualTo(_ expected: T) {
        if value != expected {
            XCTFail("expected \(expected), got \(value)", file: file, line: line)
        }
    }

    func isNotEqualTo(_ expected: T) {
        if value == expected {
            XCTFail("expected not \(expected), but was equal", file: file, line: line)
        }
    }
}

// MARK: - Comparable

extension ValueAssertion where T: Comparable {
    func isLessThan(_ other: T) {
        if !(value < other) {
            XCTFail("expected \(value) < \(other)", file: file, line: line)
        }
    }

    func isLessThanOrEqualTo(_ other: T) {
        if !(value <= other) {
            XCTFail("expected \(value) <= \(other)", file: file, line: line)
        }
    }

    func isGreaterThan(_ other: T) {
        if !(value > other) {
            XCTFail("expected \(value) > \(other)", file: file, line: line)
        }
    }

    func isGreaterThanOrEqualTo(_ other: T) {
        if !(value >= other) {
            XCTFail("expected \(value) >= \(other)", file: file, line: line)
        }
    }
}

// MARK: - Optional via mirror

extension ValueAssertion {
    /// Asserts the value is non-nil. Works for any `T` whose runtime is
    /// `Optional<U>`; the mirror approach lets us avoid a constraint on `T`.
    func isNotNil() {
        let mirror = Mirror(reflecting: value as Any)
        if mirror.displayStyle == .optional && mirror.children.isEmpty {
            XCTFail("expected non-nil, got nil", file: file, line: line)
        }
    }

    /// Asserts the value IS nil. Reciprocal of `isNotNil`.
    func isNil() {
        let mirror = Mirror(reflecting: value as Any)
        if mirror.displayStyle == .optional && !mirror.children.isEmpty {
            XCTFail("expected nil, got \(value)", file: file, line: line)
        }
    }
}

// MARK: - Collection (count / empty)

extension ValueAssertion where T: Collection {
    func isEmpty() {
        if !value.isEmpty {
            XCTFail("expected empty collection, got \(value.count) elements", file: file, line: line)
        }
    }

    func hasSize(_ expected: Int) {
        if value.count != expected {
            XCTFail("expected size \(expected), got \(value.count)", file: file, line: line)
        }
    }
}

// MARK: - String containment

extension ValueAssertion where T == String {
    func contains(_ substring: String) {
        if !value.contains(substring) {
            XCTFail("expected '\(value)' to contain '\(substring)'", file: file, line: line)
        }
    }

    func doesNotContain(_ substring: String) {
        if value.contains(substring) {
            XCTFail("expected '\(value)' to NOT contain '\(substring)'", file: file, line: line)
        }
    }
}

// MARK: - Array helpers

extension ArrayAssertion {
    func isEmpty() {
        if !actual.isEmpty {
            XCTFail("expected empty, got \(actual)", file: file, line: line)
        }
    }

    func hasSize(_ expected: Int) {
        if actual.count != expected {
            XCTFail("expected size \(expected), got \(actual.count) (\(actual))", file: file, line: line)
        }
    }
}

extension ArrayAssertion where Element: Equatable {
    func containsExactly(_ expected: [Element]) {
        if actual != expected {
            XCTFail("expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    func contains(_ expected: Element) {
        if !actual.contains(expected) {
            XCTFail("expected \(actual) to contain \(expected)", file: file, line: line)
        }
    }

    func doesNotContain(_ expected: Element) {
        if actual.contains(expected) {
            XCTFail("expected \(actual) to NOT contain \(expected)", file: file, line: line)
        }
    }

    func allEqualTo(_ expected: Element) {
        for (i, item) in actual.enumerated() where item != expected {
            XCTFail("element \(i): expected \(expected), got \(item)", file: file, line: line)
        }
    }
}
