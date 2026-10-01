//
//  PollUntil.swift
//  ForewordTests
//
//  Tiny polling helper for async tests that need to wait for a Main-actor
//  state to settle without reaching for `XCTestExpectation` everywhere.
//

import Foundation

/// Spin on the main actor until `predicate()` returns true or the deadline
/// elapses. Returns the final predicate value so the caller can assert.
@MainActor
@discardableResult
func pollUntil(
    timeoutSeconds: Double = 2.0,
    _ predicate: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !predicate() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}
