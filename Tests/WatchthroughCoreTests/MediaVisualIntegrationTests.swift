import Darwin
import Foundation
import XCTest
@testable import WatchthroughCore

final class MediaVisualIntegrationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var ffmpeg: URL!
    private var ffprobe: URL!

    override func setUpWithError() throws {
        guard let foundFFmpeg = Tooling.find("ffmpeg"),
              let foundFFprobe = Tooling.find("ffprobe") else {
            throw XCTSkip("FFmpeg and FFprobe are required for media integration tests")
        }
        ffmpeg = foundFFmpeg
        ffprobe = foundFFprobe
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-media-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testFrameAccurateProbeExtractionAndVisualChangeHint() throws {
        let video = temporaryDirectory.appendingPathComponent("hard-cut.mkv")
        try runFFmpeg([
            "-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=2",
            "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=2",
            "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
            "-map", "[v]", "-c:v", "ffv1", video.path,
        ])

        let probed = try MediaProbe.probe(video, ffprobe: ffprobe.path)
        XCTAssertEqual(probed.info.frameCount, 120)
        XCTAssertEqual(probed.frames.first?.ordinal, 0)
        XCTAssertEqual(probed.frames.last?.ordinal, 119)
        XCTAssertLessThan(probed.frames.first!.ptsSeconds, probed.frames.last!.ptsSeconds)

        let overview = try FrameSelector.overview(maxCount: 12, in: probed.frames)
        XCTAssertEqual(overview.count, 12)
        XCTAssertEqual(overview.first, probed.frames.first)
        XCTAssertEqual(overview.last, probed.frames.last)

        let argumentLog = temporaryDirectory.appendingPathComponent("ffmpeg-arguments.txt")
        let environmentLog = temporaryDirectory.appendingPathComponent("ffmpeg-environment.txt")
        let ffmpegWrapper = temporaryDirectory.appendingPathComponent("ffmpeg-wrapper.sh")
        try Data(
            """
            #!/bin/sh
            if [ "${ELEVENLABS_API_KEY+x}" = x ]; then
              printf 'present\\n' > '\(environmentLog.path)'
            else
              printf 'absent\\n' > '\(environmentLog.path)'
            fi
            printf '%s\\n' "$@" > '\(argumentLog.path)'
            exec '\(ffmpeg.path)' "$@"
            """.utf8
        ).write(to: ffmpegWrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: ffmpegWrapper.path
        )
        let frameDirectory = temporaryDirectory.appendingPathComponent("frames", isDirectory: true)
        let extracted = try FrameExtractor.extract(
            source: video,
            selectedFrames: [probed.frames[0], probed.frames[60], probed.frames[119]],
            frameIndex: probed.frames,
            destinationDirectory: frameDirectory,
            maximumWidth: 160,
            ffmpegPath: ffmpegWrapper.path
        )
        XCTAssertEqual(extracted.map(\.ordinal), [0, 60, 119])
        for frame in extracted {
            let size = try frame.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertGreaterThan(size, 0)
        }
        let extractionArguments = try String(contentsOf: argumentLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        let frameLimitIndex = try XCTUnwrap(extractionArguments.firstIndex(of: "-frames:v"))
        XCTAssertEqual(extractionArguments[frameLimitIndex + 1], "3")

        let credentialName = "ELEVENLABS_API_KEY"
        let fixtureSecret = "fixture-secret-must-not-cross-streaming-process-boundary"
        let previousValue = getenv(credentialName).map { String(cString: $0) }
        XCTAssertEqual(setenv(credentialName, fixtureSecret, 1), 0)
        defer {
            if let previousValue {
                setenv(credentialName, previousValue, 1)
            } else {
                unsetenv(credentialName)
            }
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment[credentialName], fixtureSecret)

        let events = try VisualAnalyzer.scan(
            source: video,
            media: probed.info,
            ffmpegPath: ffmpegWrapper.path
        )
        XCTAssertEqual(
            try String(contentsOf: environmentLog, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "absent"
        )
        XCTAssertEqual(events.scanFPS, 2, accuracy: 0.000_001)
        XCTAssertEqual(events.samples.count, 8)
        XCTAssertEqual(events.events.first?.id, "E0001")
        XCTAssertTrue(events.events.contains { abs($0.peakSeconds - 2) <= 1 })
    }

    func testVariableFrameRateIndexPreservesDecodedTimestampsAndTrueTail() throws {
        let video = temporaryDirectory.appendingPathComponent("vfr.mkv")
        try runFFmpeg([
            "-f", "lavfi", "-i", "color=c=red:s=160x90:d=1:r=10",
            "-f", "lavfi", "-i", "color=c=blue:s=160x90:d=1:r=5",
            "-filter_complex",
            "[0:v]settb=AVTB[v0];[1:v]settb=AVTB[v1];[v0][v1]concat=n=2:v=1:a=0[v]",
            "-map", "[v]", "-fps_mode", "vfr", "-c:v", "ffv1", video.path,
        ])

        let probed = try MediaProbe.probe(video, ffprobe: ffprobe.path)
        XCTAssertEqual(probed.frames.count, 15)
        let gaps = zip(probed.frames, probed.frames.dropFirst()).map {
            $1.ptsSeconds - $0.ptsSeconds
        }
        XCTAssertTrue(gaps.contains { abs($0 - 0.1) < 0.001 })
        XCTAssertTrue(gaps.contains { abs($0 - 0.2) < 0.001 })

        let indexURL = temporaryDirectory.appendingPathComponent("frame-index.tsv")
        try FrameIndexTSV.write(probed.frames, to: indexURL)
        XCTAssertEqual(try FrameIndexTSV.read(from: indexURL), probed.frames)

        let overview = try FrameSelector.overview(maxCount: 7, in: probed.frames)
        XCTAssertEqual(overview.first, probed.frames.first)
        XCTAssertEqual(overview.last, probed.frames.last)
        XCTAssertEqual(overview.last!.ptsSeconds, 1.8, accuracy: 0.001)

        let extracted = try FrameExtractor.extract(
            source: video,
            selectedFrames: [probed.frames.last!],
            frameIndex: probed.frames,
            destinationDirectory: temporaryDirectory.appendingPathComponent("vfr-tail", isDirectory: true),
            maximumWidth: 160,
            ffmpegPath: ffmpeg.path
        )
        XCTAssertEqual(extracted.map(\.ordinal), [14])
    }

    func testVisualEventsRemainOnNonzeroDecodedTimeline() throws {
        let video = temporaryDirectory.appendingPathComponent("nonzero-start.mkv")
        try runFFmpeg([
            "-f", "lavfi", "-i", "color=c=red:s=320x180:r=30:d=2",
            "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=2",
            "-filter_complex",
            "[0:v][1:v]concat=n=2:v=1:a=0,setpts=PTS+5/TB[v]",
            "-map", "[v]", "-c:v", "ffv1", video.path,
        ])

        let probed = try MediaProbe.probe(video, ffprobe: ffprobe.path)
        XCTAssertEqual(probed.frames.first!.ptsSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(probed.frames.last!.ptsSeconds, 8.967, accuracy: 0.001)
        XCTAssertEqual(probed.info.durationSeconds, 4, accuracy: 0.01)

        let events = try VisualAnalyzer.scan(
            source: video,
            media: probed.info,
            ffmpegPath: ffmpeg.path
        )
        let strongest = try XCTUnwrap(events.events.first)
        XCTAssertEqual(strongest.peakSeconds, 7, accuracy: 0.51)
        XCTAssertGreaterThanOrEqual(strongest.startSeconds, probed.info.firstPTS)
        XCTAssertLessThanOrEqual(strongest.endSeconds, probed.info.lastPTS)

        let routed = try FrameSelector.everySeconds(
            0.5,
            in: probed.frames,
            range: (
                max(probed.info.firstPTS, strongest.startSeconds - 1)
                    ... min(probed.info.lastPTS, strongest.endSeconds + 1)
            )
        )
        XCTAssertGreaterThan(routed.count, 1)
        XCTAssertTrue(routed.contains { abs($0.ptsSeconds - strongest.peakSeconds) <= 0.51 })

        let argumentLog = temporaryDirectory.appendingPathComponent("seek-arguments.txt")
        let wrapper = temporaryDirectory.appendingPathComponent("seek-ffmpeg.sh")
        try Data(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(argumentLog.path)'\nexec '\(ffmpeg.path)' \"$@\"\n".utf8
        ).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let extracted = try FrameExtractor.extract(
            source: video,
            selectedFrames: [probed.frames[60], probed.frames[119]],
            frameIndex: probed.frames,
            destinationDirectory: temporaryDirectory.appendingPathComponent("nonzero-late", isDirectory: true),
            maximumWidth: 160,
            ffmpegPath: wrapper.path
        )
        XCTAssertEqual(extracted.map(\.ordinal), [60, 119])
        let arguments = try String(contentsOf: argumentLog, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        let seekFlag = try XCTUnwrap(arguments.firstIndex(of: "-ss"))
        let seek = try XCTUnwrap(Double(arguments[seekFlag + 1]))
        XCTAssertGreaterThan(seek, 0)
        XCTAssertLessThan(seek, 2.1)
        let filterFlag = try XCTUnwrap(arguments.firstIndex(of: "-vf"))
        XCTAssertTrue(arguments[filterFlag + 1].contains("eq(n\\,"))
    }

    private func runFFmpeg(_ arguments: [String]) throws {
        _ = try ProcessRunner.run(
            ffmpeg.path,
            arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + arguments,
            timeout: 30
        ).requireSuccess("could not generate synthetic video")
    }
}
