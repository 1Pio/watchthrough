import XCTest
@testable import WatchthroughCore

final class RenderTests: XCTestCase {
    func testContactSheetGridBalancesRowsWithinFiveColumns() {
        XCTAssertEqual(StripRenderer.gridDimensions(itemCount: 15).columns, 5)
        XCTAssertEqual(StripRenderer.gridDimensions(itemCount: 15).rows, 3)
        XCTAssertEqual(StripRenderer.gridDimensions(itemCount: 6).columns, 3)
        XCTAssertEqual(StripRenderer.gridDimensions(itemCount: 6).rows, 2)
        XCTAssertEqual(StripRenderer.gridDimensions(itemCount: 3).columns, 3)
        XCTAssertEqual(StripRenderer.gridDimensions(itemCount: 3).rows, 1)
    }

    func testPacketMarkdownKeepsSubsecondIntervalEvidence() {
        let cell = PacketCell(
            index: 0,
            ordinal: 10,
            ptsSeconds: 1.25,
            intervalStartSeconds: 1,
            intervalEndSeconds: 1.5,
            timestamp: "00:01.250",
            caption: "",
            framePath: "frames/frame-o00000010.jpg"
        )
        let packet = InspectionPacket(
            selector: "00:01",
            sourcePath: "/fixture/video.mp4",
            rangeStartSeconds: 1,
            rangeEndSeconds: 1.5,
            sampling: "every 0.5s",
            cellsPerSheet: 15,
            largestGapSeconds: 0,
            timingPrecision: .none,
            cells: [cell],
            sheets: []
        )

        let markdown = PacketMarkdown.render(packet)
        XCTAssertTrue(markdown.contains("interval 00:01 to 00:01.500"))
    }

    func testPacketMarkdownPreservesSignedPresentationTime() {
        let cell = PacketCell(
            index: 0,
            ordinal: 0,
            ptsSeconds: -0.08,
            intervalStartSeconds: -0.1,
            intervalEndSeconds: 0,
            timestamp: "-00:00.080",
            caption: "",
            framePath: "frames/frame-o00000000.jpg"
        )
        let packet = InspectionPacket(
            selector: "-00:00.080",
            sourcePath: "/fixture/video.mp4",
            rangeStartSeconds: -0.1,
            rangeEndSeconds: 0,
            sampling: "single resolved frame",
            cellsPerSheet: 15,
            largestGapSeconds: 0,
            timingPrecision: .none,
            cells: [cell],
            sheets: []
        )
        let markdown = PacketMarkdown.render(packet)
        XCTAssertTrue(markdown.contains("Range: -00:00.100 to 00:00"))
        XCTAssertTrue(markdown.contains("interval -00:00.100 to 00:00"))
    }
}
