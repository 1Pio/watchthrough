import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import WatchthroughCore

final class RenderTests: XCTestCase {
    func testPortraitFramesFitBoundedImageAreaWithoutStretching() {
        let portrait = StripRenderer.fittedImageSize(width: 64, height: 4096, cellWidth: 360)
        XCTAssertEqual(portrait.height, 640)
        XCTAssertEqual(portrait.width, 10)
        let landscape = StripRenderer.fittedImageSize(width: 1920, height: 1080, cellWidth: 360)
        XCTAssertEqual(landscape.width, 360)
        XCTAssertEqual(landscape.height, 203)
    }

    func testNativeRenderingBoundsPortraitCanvasAndWritesBothFormats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("portrait.png")
        try writePattern(width: 64, height: 4096, to: source)
        let cells = (0..<20).map { index in
            PacketCell(index: index, ordinal: index, ptsSeconds: Double(index),
                       intervalStartSeconds: Double(index), intervalEndSeconds: Double(index + 1),
                       timestamp: CLIParser.formatTime(Double(index)),
                       caption: "A tall source stays proportional. Full detail is available in the selected frame.",
                       framePath: "portrait.png")
        }
        for format in [StripImageFormat.jpeg, .png] {
            let output = root.appendingPathComponent(format.rawValue)
            let paths = try StripRenderer.render(cells: cells, framesBaseURL: root, destinationDirectory: output,
                                                options: StripRenderOptions(maximumCellsPerSheet: 20, format: format))
            XCTAssertEqual(paths.count, 1)
            XCTAssertEqual(paths[0].pathExtension, format.fileExtension)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(paths[0] as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
            XCTAssertEqual(width, 1800)
            XCTAssertLessThanOrEqual(height, 3200)
            XCTAssertLessThanOrEqual(width * height, StripRenderOptions.hardMaximumCanvasPixels)
        }
    }

    /// Explicit benchmark only: does not decode video or run in the normal suite.
    func testOptInRenderBenchmark() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["WATCHTHROUGH_RENDER_BENCHMARK"] else {
            throw XCTSkip("Set WATCHTHROUGH_RENDER_BENCHMARK to a new output directory for render measurements.")
        }
        let root = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source: URL
        if let provided = ProcessInfo.processInfo.environment["WATCHTHROUGH_RENDER_SOURCE"] {
            source = URL(fileURLWithPath: provided)
        } else {
            source = root.appendingPathComponent("source.png")
            try writePattern(width: 1920, height: 1080, to: source)
        }
        var cells: [PacketCell] = []
        for index in 0..<15 {
            let start: Double = Double(index) / 60.0
            let end: Double = Double(index + 1) / 60.0
            let caption = "Frame \(index): 10.5 ms, x = 128. A clear caption and subtle image detail."
            cells.append(PacketCell(index: index, ordinal: index, ptsSeconds: start,
                                    intervalStartSeconds: start, intervalEndSeconds: end,
                                    timestamp: CLIParser.formatTime(start), caption: caption,
                                    framePath: source.path))
        }
        var records: [[String: Any]] = []
        for repetition in 0..<5 {
            for format in [StripImageFormat.png, .jpeg] {
                let output = root.appendingPathComponent("\(format.rawValue)-\(repetition)")
                let start = ProcessInfo.processInfo.systemUptime
                let paths = try StripRenderer.render(cells: cells, framesBaseURL: root, destinationDirectory: output,
                                                    options: StripRenderOptions(format: format))
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                var bytes = 0
                for url in paths {
                    bytes += try url.resourceValues(forKeys: [URLResourceKey.fileSizeKey]).fileSize ?? 0
                }
                records.append(["format": format.rawValue, "iteration": repetition, "seconds": elapsed,
                                "bytes": bytes, "path": paths[0].path])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"), options: .atomic)
        print("Render benchmark: \(root.appendingPathComponent("results.json").path)")
    }

    private func writePattern(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let seed = UInt64(x &* 71 ^ y &* 983)
                context.setFillColor(CGColor(red: Double(seed % 251) / 250,
                                             green: Double(seed % 199) / 198,
                                             blue: Double(seed % 173) / 172, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
    }

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

    func testPacketMarkdownDoesNotInventGlobalOrdinalForRegionalFrame() {
        let cell = PacketCell(index: 0, ordinal: nil, ptsSeconds: 12.5,
                              intervalStartSeconds: 12.5, intervalEndSeconds: 13,
                              timestamp: "00:12.500", caption: "", framePath: "frames/frame.jpg",
                              ordinalBasis: "regional", localOrdinal: 4)
        let packet = InspectionPacket(selector: "12..13", sourcePath: "/fixture/video.mp4",
                                      rangeStartSeconds: 12, rangeEndSeconds: 13,
                                      sampling: "every 1 decoded regional frame", cellsPerSheet: 15,
                                      largestGapSeconds: 0, timingPrecision: .none, cells: [cell], sheets: [])
        let markdown = PacketMarkdown.render(packet)
        XCTAssertTrue(markdown.contains("regional decoded frame `4` (not a global ordinal)"))
        XCTAssertFalse(markdown.contains("Optional("))
    }
}
