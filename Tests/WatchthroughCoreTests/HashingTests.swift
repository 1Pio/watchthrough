import Foundation
import XCTest
@testable import WatchthroughCore

final class HashingTests: XCTestCase {
    func testKnownAnswersIncludeEmptyInputAndShortFinalReads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        XCTAssertEqual(try FileSHA256.hexDigest(of: file), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try Data("abc".utf8).write(to: file)
        for chunkSize in [1, 2, 3, 64] {
            XCTAssertEqual(try FileSHA256.hexDigest(of: file, chunkSize: chunkSize),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "chunk size \(chunkSize)")
        }
    }

    func testMultiChunkDigestIsIndependentOfReadBoundary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        // Fixed known answer generated independently with Python hashlib.
        try Data(repeating: 0x5a, count: 2 * 1_024 * 1_024 + 1).write(to: file)
        let expected = "86a0b5ce099dfb5f33f4993acfcde61a12df4009a2c80908997fa81c700716f7"
        for chunkSize in [1_024, 65_536, 1_048_576, 1_048_579, 8_388_608] {
            XCTAssertEqual(try FileSHA256.hexDigest(of: file, chunkSize: chunkSize), expected, "chunk size \(chunkSize)")
        }
    }

    func testHashingRejectsInvalidChunkSizesAndUnreadableInput() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-missing-hash-\(UUID().uuidString)")
        for chunkSize in [0, -1] {
            XCTAssertThrowsError(try FileSHA256.hexDigest(of: missing, chunkSize: chunkSize)) { error in
                XCTAssertEqual((error as? WatchthroughFailure)?.category, .usage)
            }
        }
        XCTAssertThrowsError(try FileSHA256.hexDigest(of: missing)) { error in
            XCTAssertEqual((error as? WatchthroughFailure)?.category, .readiness)
        }
    }
}
