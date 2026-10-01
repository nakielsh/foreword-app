//
//  PreReviewSummaryRunnerTests.swift
//  ForewordTests
//
//  Tests for `PreReviewSummaryRunner` covering both the new
//  `--output-format json` whole-blob path (`decodeJSONOutput`) and the
//  legacy `decodeLine` helpers retained for back-compat.
//

import XCTest
@testable import Foreword

final class PreReviewSummaryRunnerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PreReviewSummaryRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - decodeJSONOutput (new --output-format json shape)

    func testDecodeJSONOutputArrayWithStructuredOutput() {
        let payload = """
        [
          {"type":"system","subtype":"init"},
          {"type":"assistant","message":{}},
          {"type":"result","subtype":"success","result":"Done.","structured_output":{"text":"PR adds retry logic for transient failures."}}
        ]
        """
        let events = PreReviewSummaryRunner.decodeJSONOutput(Data(payload.utf8))
        XCTAssertEqual(events.count, 1)
        guard case .result(let text) = events[0] else {
            XCTFail("expected .result, got \(events[0])")
            return
        }
        XCTAssertEqual(text, "PR adds retry logic for transient failures.")
    }

    func testDecodeJSONOutputArrayResultStringFallback() {
        // No structured_output, plain result string holding inline JSON.
        let payload = """
        [
          {"type":"result","subtype":"success","result":"{\\"text\\":\\"Bumps timeout from 30 to 60 seconds.\\"}"}
        ]
        """
        let events = PreReviewSummaryRunner.decodeJSONOutput(Data(payload.utf8))
        guard case .result(let text) = events.first else {
            XCTFail("expected .result, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(text, "Bumps timeout from 30 to 60 seconds.")
    }

    func testDecodeJSONOutputErrorSubtype() {
        let payload = """
        [
          {"type":"result","subtype":"error_max_turns","result":"hit max turns"}
        ]
        """
        let events = PreReviewSummaryRunner.decodeJSONOutput(Data(payload.utf8))
        guard case .error(let message) = events.first else {
            XCTFail("expected .error, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(message, "hit max turns")
    }

    func testDecodeJSONOutputNoResultEvent() {
        let payload = """
        [
          {"type":"system","subtype":"init"},
          {"type":"assistant","message":{}}
        ]
        """
        let events = PreReviewSummaryRunner.decodeJSONOutput(Data(payload.utf8))
        guard case .error(let message) = events.first else {
            XCTFail("expected .error, got \(String(describing: events.first))")
            return
        }
        XCTAssertTrue(message.contains("no result event"), "message must mention missing result; got \(message)")
    }

    func testDecodeJSONOutputEmpty() {
        let events = PreReviewSummaryRunner.decodeJSONOutput(Data())
        guard case .error = events.first else {
            XCTFail("empty stdout must yield .error")
            return
        }
    }

    // MARK: - decodeLine (legacy stream-json — kept for callers that still use it)

    func testDecodeLineTextDeltaYieldsDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"foo"}}}"#
        let events = PreReviewSummaryRunner.decodeLine(line)
        XCTAssertEqual(events.count, 1)
        guard case .delta(let text) = events[0] else {
            XCTFail("expected .delta; got \(events[0])")
            return
        }
        XCTAssertEqual(text, "foo")
    }

    func testDecodeLineUnknownTypeIsDropped() {
        let line = #"{"type":"assistant","message":{}}"#
        let events = PreReviewSummaryRunner.decodeLine(line)
        XCTAssertTrue(events.isEmpty, "assistant bookkeeping must be dropped")
    }

    // MARK: - decodeSummaryPayload (string → SummarySchema)

    func testDecodeSummaryPayloadPlain() {
        let events = PreReviewSummaryRunner.decodeSummaryPayload(#"{"text":"hello"}"#)
        guard case .result(let text) = events.first else {
            XCTFail("expected .result")
            return
        }
        XCTAssertEqual(text, "hello")
    }

    func testDecodeSummaryPayloadFenced() {
        let fenced = "```json\n{\"text\":\"fenced\"}\n```"
        let events = PreReviewSummaryRunner.decodeSummaryPayload(fenced)
        guard case .result(let text) = events.first else {
            XCTFail("expected .result")
            return
        }
        XCTAssertEqual(text, "fenced")
    }
}
