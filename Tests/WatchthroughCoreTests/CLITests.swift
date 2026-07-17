import XCTest
@testable import WatchthroughCore

final class CLITests: XCTestCase {
    func testSignedPresentationTimesAndFormattingCarry() throws {
        XCTAssertEqual(try CLIParser.parseTime("-00:00.080"), -0.08, accuracy: 0.000_001)
        XCTAssertEqual(try CLIParser.parseTime("+01:02.500"), 62.5, accuracy: 0.000_001)
        XCTAssertEqual(CLIParser.formatTime(-0.08), "-00:00.080")
        XCTAssertEqual(CLIParser.formatTime(59.9999), "01:00.000")
        XCTAssertEqual(CLIParser.formatTime(3_599.9999), "01:00:00.000")
        XCTAssertEqual(try CLIParser.parseTime(CLIParser.formatTime(59.9999)), 60)
    }

    func testParsesSmallPublicSurface() throws {
        for command in ["prepare", "inspect", "status"] {
            let invocation = try CLIParser.parse([command, "--help"])
            guard case .help = invocation.command else {
                return XCTFail("expected \(command) --help to show help")
            }
        }

        let prepare = try CLIParser.parse([
            "--json", "prepare", "/tmp/source.mp4",
            "--out", "/tmp/source.watchthrough",
            "--transcriber", "macparakeet",
            "--refresh",
        ])
        XCTAssertTrue(prepare.json)
        guard case let .prepare(options) = prepare.command else {
            return XCTFail("expected prepare")
        }
        XCTAssertEqual(options.source.path, "/tmp/source.mp4")
        XCTAssertEqual(options.output?.path, "/tmp/source.watchthrough")
        XCTAssertEqual(options.transcriber, "macparakeet")
        XCTAssertTrue(options.refresh)

        let inspect = try CLIParser.parse([
            "inspect", "/tmp/source.watchthrough", "12:30..12:45",
            "--every", "10f", "--cells", "20",
        ])
        guard case let .inspect(options) = inspect.command else {
            return XCTFail("expected inspect")
        }
        XCTAssertEqual(options.selector, .range(750, 765))
        XCTAssertEqual(options.every, .frames(10))
        XCTAssertEqual(options.cells, 20)
    }

    func testRejectsURLAndCloudNeverHidesBehindAuto() throws {
        XCTAssertThrowsError(try CLIParser.parse([
            "prepare", "https://www.youtube.com/watch?v=abc",
        ]))
        let parsed = try CLIParser.parse(["prepare", "/tmp/source.mp4"])
        guard case let .prepare(options) = parsed.command else {
            return XCTFail("expected prepare")
        }
        XCTAssertEqual(options.transcriber, "auto")
    }

    func testTimeAndSamplingParsing() throws {
        XCTAssertEqual(try CLIParser.parseTime("12.5"), 12.5, accuracy: 0.0001)
        XCTAssertEqual(try CLIParser.parseTime("12:30.250"), 750.25, accuracy: 0.0001)
        XCTAssertEqual(try CLIParser.parseTime("1:02:03.5"), 3_723.5, accuracy: 0.0001)
        XCTAssertEqual(try CLIParser.parseDuration("500ms"), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try CLIParser.parseSampling("2s"), .seconds(2))
        XCTAssertEqual(try CLIParser.parseSampling("10f"), .frames(10))
        XCTAssertThrowsError(try CLIParser.parseTime("1:61"))
        XCTAssertThrowsError(try CLIParser.parseSampling("0f"))
    }

    func testSelectors() throws {
        XCTAssertEqual(try CLIParser.parseSelector("overview"), .overview)
        XCTAssertEqual(try CLIParser.parseSelector("events"), .events)
        XCTAssertEqual(try CLIParser.parseSelector("event:E0042"), .event("E0042"))
        XCTAssertEqual(try CLIParser.parseSelector("frame:18720"), .frame(18_720))
        XCTAssertEqual(try CLIParser.parseSelector("00:10.500"), .time(10.5))
        XCTAssertEqual(try CLIParser.parseSelector("00:10..00:12"), .range(10, 12))
        XCTAssertThrowsError(try CLIParser.parseSelector("event:42"))
        XCTAssertThrowsError(try CLIParser.parseSelector("10..2"))
    }

    func testBalancedPaginationAvoidsSingletonTail() {
        XCTAssertEqual(StripRenderer.balancedPageSizes(itemCount: 15), [15])
        XCTAssertEqual(StripRenderer.balancedPageSizes(itemCount: 16), [8, 8])
        XCTAssertEqual(StripRenderer.balancedPageSizes(itemCount: 31), [11, 10, 10])
        let sizes = StripRenderer.balancedPageSizes(itemCount: 101, maximumPerPage: 20)
        XCTAssertEqual(sizes.reduce(0, +), 101)
        XCTAssertLessThanOrEqual((sizes.max() ?? 0) - (sizes.min() ?? 0), 1)
        XCTAssertLessThanOrEqual(sizes.max() ?? 0, 20)
    }
}
