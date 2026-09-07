import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import WatchthroughCore

final class TemporalTests: XCTestCase {
    private var directory: URL!
    private var ffmpeg: URL!
    private var ffprobe: URL!

    override func setUpWithError() throws {
        guard let encoder = Tooling.find("ffmpeg"), let probe = Tooling.find("ffprobe") else {
            throw XCTSkip("FFmpeg and FFprobe are required")
        }
        ffmpeg = encoder
        ffprobe = probe
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("watchthrough-temporal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testReceiptsUseIntegerPTSAndTimeBaseRatherThanRoundedDisplay() throws {
        let receipts = try FramePTSReceipts.parse("""
        [Parsed_showinfo_1 @ 0x0] config in time_base: 1/15360, frame_rate: 30/1
        [Parsed_showinfo_1 @ 0x0] n: 0 pts: -512 pts_time:-0.0333333 duration:512
        [Parsed_showinfo_1 @ 0x0] n: 1 pts: 512 pts_time:0.0333333 duration:512
        [Parsed_showinfo_1 @ 0x0] n: 2 pts: 512 pts_time:0.0333333 duration:512
        """)
        XCTAssertEqual(receipts, [-1.0 / 30, 1.0 / 30, 1.0 / 30])
        XCTAssertThrowsError(try FramePTSReceipts.parse("[Parsed_showinfo_0 @ 0] n: 0 pts: 5 pts_time:5"))
    }

    func testStreamedFrameIndexHandlesSplitRecordsAndRejectsMissingTimestamps() throws {
        let collector = FrameIndexCollector()
        try collector.consume(Data("frame|best_effort_timestamp_time=-0.033".utf8))
        try collector.consume(Data("333|side_data_type=fixture\nframe|best_effort_timestamp_time=0\nframe|best_effort_timestamp_time=0".utf8))
        XCTAssertEqual(try collector.finish(), [FramePoint(ordinal: 0, ptsSeconds: -0.033333),
                                               FramePoint(ordinal: 1, ptsSeconds: 0), FramePoint(ordinal: 2, ptsSeconds: 0)])
        let missing = FrameIndexCollector()
        XCTAssertThrowsError(try missing.consume(Data("frame|side_data_type=missing\n".utf8)))
        let reversed = FrameIndexCollector()
        XCTAssertThrowsError(try reversed.consume(Data("frame|best_effort_timestamp_time=1\nframe|best_effort_timestamp_time=0\n".utf8)))
    }

    func testMetadataAvoidsDecodedFrameIndexAndKeepsSeparateAudioOrigin() throws {
        let source = directory.appendingPathComponent("source.mp4")
        try Data("fixture".utf8).write(to: source)
        let arguments = directory.appendingPathComponent("arguments")
        let probe = directory.appendingPathComponent("probe")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" > '\(arguments.path)'
        cat <<'JSON'
        {"streams":[{"codec_type":"video","width":1920,"height":1080,"start_time":"5","duration":"12","side_data_list":[{"rotation":90}]},{"codec_type":"audio","start_time":"5.75"}],"format":{"duration":"17","start_time":"5","format_name":"matroska,webm"}}
        JSON
        """.utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
        let media = try MediaProbe.metadata(source, ffprobe: probe.path)
        XCTAssertEqual(media.frameCount, 0)
        XCTAssertEqual(media.firstPTS, 5)
        XCTAssertEqual(media.lastPTS, 17)
        XCTAssertEqual(media.audioStartPTS, 5.75)
        XCTAssertEqual(media.width, 1080)
        XCTAssertEqual(media.height, 1920)
        XCTAssertFalse(try String(contentsOf: arguments, encoding: .utf8).contains("-show_frames"))
    }

    func testMissingContainerDurationFallsBackToDecodedTimingOnlyWhenNecessary() throws {
        let source = directory.appendingPathComponent("live-muxed.mkv")
        try encode(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=24:d=2", "-c:v", "libx264", "-preset", "ultrafast",
                    "-live", "1", source.path])
        let raw = try ProcessRunner.run(ffprobe.path, arguments: ["-v", "error", "-show_entries", "format=duration:stream=duration",
                                                                "-of", "json", source.path]).requireSuccess()
        XCTAssertFalse(raw.stdout.contains("\"duration\""), "fixture must omit duration from container and streams")
        let log = directory.appendingPathComponent("probe-log")
        let wrapper = directory.appendingPathComponent("ffprobe-wrapper")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" >> '\(log.path)'\nexec '\(ffprobe.path)' \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let media = try MediaProbe.metadata(source, ffprobe: wrapper.path)
        XCTAssertEqual(media.frameCount, 48, "nonzero count identifies the expensive duration fallback")
        XCTAssertEqual(media.durationSeconds, 2, accuracy: 0.002)
        XCTAssertEqual(media.firstPTS, 0)
        XCTAssertEqual(media.lastPTS, 47.0 / 24, accuracy: 0.001)
        let arguments = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(arguments.components(separatedBy: "-show_frames").count - 1, 1)
    }

    func testLongGOPDenseAndSparseImagesMatchIndependentFullDecode() throws {
        let source = directory.appendingPathComponent("long-gop.mp4")
        try encode(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=12", "-c:v", "libx264", "-preset", "fast",
                    "-g", "360", "-keyint_min", "360", "-sc_threshold", "0", "-bf", "3", source.path])
        let metadata = try MediaProbe.metadata(source, ffprobe: ffprobe.path)
        XCTAssertEqual(metadata.frameCount, 0)
        let reference = try MediaProbe.probe(source, ffprobe: ffprobe.path)
        let range = 10.001...10.201
        let expected = reference.frames.filter { range.contains($0.ptsSeconds) }
        let dense = try TemporalExtractor.extract(source: source, media: metadata, range: range, every: .frames(1),
                                                  destinationDirectory: directory.appendingPathComponent("dense"), maximumWidth: nil, ffmpegPath: ffmpeg.path)
        XCTAssertEqual(dense.count, expected.count)
        for (position, pair) in zip(dense, expected).enumerated() {
            XCTAssertEqual(pair.0.ptsSeconds, pair.1.ptsSeconds, accuracy: 0.000_001)
            XCTAssertEqual(pair.0.localOrdinal, position)
        }
        try assertPixels(dense, match: expected, source: source)
        let sparsePoints = [reference.frames[1], reference.frames[177], reference.frames[350]]
        let sparse = try TemporalExtractor.extract(source: source, media: metadata, times: sparsePoints.map(\.ptsSeconds),
                                                   destinationDirectory: directory.appendingPathComponent("sparse"), maximumWidth: nil, ffmpegPath: ffmpeg.path)
        try assertPixels(sparse, match: sparsePoints, source: source)
        let tail = try TemporalExtractor.tail(source: source, media: metadata,
                                             destinationDirectory: directory.appendingPathComponent("tail"), maximumWidth: nil,
                                             ffmpegPath: ffmpeg.path, ffprobePath: ffprobe.path)
        XCTAssertEqual(tail.ptsSeconds, reference.frames.last!.ptsSeconds, accuracy: 0.000_001)
        try assertPixels([tail], match: [reference.frames.last!], source: source)
    }

    func testVFRDenseFractionalBoundaryAndGlobalOrdinalRemainExact() throws {
        let source = directory.appendingPathComponent("vfr.mkv")
        try encode([
            "-f", "lavfi", "-i", "testsrc2=s=160x90:r=24:d=2",
            "-f", "lavfi", "-i", "testsrc2=s=160x90:r=60:d=2",
            "-filter_complex", "[0:v]settb=AVTB[a];[1:v]settb=AVTB[b];[a][b]concat=n=2:v=1:a=0[v]",
            "-map", "[v]", "-fps_mode", "vfr", "-c:v", "libx264", "-preset", "fast", "-g", "300", source.path,
        ])
        let metadata = try MediaProbe.metadata(source, ffprobe: ffprobe.path)
        let reference = try MediaProbe.probe(source, ffprobe: ffprobe.path)
        let range = 3.301...3.501
        let all = reference.frames.filter { range.contains($0.ptsSeconds) }
        let expected = all.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let dense = try TemporalExtractor.extract(source: source, media: metadata, range: range, every: .frames(2),
                                                  destinationDirectory: directory.appendingPathComponent("dense"), maximumWidth: nil, ffmpegPath: ffmpeg.path)
        XCTAssertEqual(dense.count, expected.count)
        for (position, pair) in zip(dense, expected).enumerated() {
            XCTAssertEqual(pair.0.ptsSeconds, pair.1.ptsSeconds, accuracy: 0.000_001)
            XCTAssertEqual(pair.0.localOrdinal, position * 2)
        }
        try assertPixels(dense, match: expected, source: source)
        let global = try FrameExtractor.extract(source: source, selectedFrames: expected, frameIndex: reference.frames,
                                                destinationDirectory: directory.appendingPathComponent("global"), maximumWidth: nil, ffmpegPath: ffmpeg.path)
        try assertPixels(global.map { TemporalFrame(ptsSeconds: reference.frames[$0.ordinal].ptsSeconds, url: $0.url) },
                         match: expected, source: source)
    }

    func testExactGlobalFramePreservesContainerOriginWhenAudioPrecedesVideo() throws {
        let source = directory.appendingPathComponent("delayed-video.mkv")
        try encode([
            "-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=3",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
            "-filter_complex", "[0:v]setpts=PTS+5/TB[v]", "-map", "[v]", "-map", "1:a",
            "-c:v", "libx264", "-g", "90", "-c:a", "pcm_s16le", "-fps_mode", "passthrough", source.path,
        ])
        let reference = try MediaProbe.probe(source, ffprobe: ffprobe.path)
        XCTAssertEqual(reference.info.firstPTS, 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reference.info.containerStartPTS), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reference.info.audioStartPTS), 0, accuracy: 0.001)
        let point = reference.frames[61]
        XCTAssertEqual(point.ptsSeconds, 7.033, accuracy: 0.001)
        // The direct API must resolve container timing even without caller metadata.
        let direct = try FrameExtractor.extract(source: source, selectedFrames: [point], frameIndex: reference.frames,
            destinationDirectory: directory.appendingPathComponent("direct-global"), maximumWidth: nil, ffmpegPath: ffmpeg.path)
        XCTAssertEqual(direct.map(\.ordinal), [61])
        try assertPixels(direct.map { TemporalFrame(ptsSeconds: point.ptsSeconds, url: $0.url) }, match: [point], source: source)
        // The CLI already has this metadata and should pass it through without re-probing.
        let analysis = directory.appendingPathComponent("analysis")
        _ = try WatchthroughApplication().run(arguments: ["prepare", source.path, "--out", analysis.path, "--transcriber", "none"])
        _ = try WatchthroughApplication().run(arguments: ["inspect", analysis.path, "frame:61"])
        let inspections = analysis.appendingPathComponent("inspections")
        let packetRoot = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: inspections, includingPropertiesForKeys: nil)
            .first { !$0.lastPathComponent.hasPrefix(".") })
        let packet = try StableJSON.decode(InspectionPacket.self, from: packetRoot.appendingPathComponent("packet.json"))
        let cell = try XCTUnwrap(packet.cells.first)
        XCTAssertEqual(cell.ordinal, 61)
        XCTAssertEqual(cell.ptsSeconds, point.ptsSeconds, accuracy: 0.000_001)
        try assertPixels([TemporalFrame(ptsSeconds: cell.ptsSeconds, url: packetRoot.appendingPathComponent(cell.framePath))],
            match: [point], source: source)
    }

    func testShortSparseSpanSharesDecodeAcrossLargerGapsWithoutDuplicatingFrames() throws {
        let source = directory.appendingPathComponent("short.mp4")
        try encode(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=4", "-c:v", "libx264", source.path])
        let log = directory.appendingPathComponent("invocations")
        let wrapper = directory.appendingPathComponent("ffmpeg-wrapper")
        try Data("#!/bin/sh\nprintf 'call\\n' >> '\(log.path)'\nexec '\(ffmpeg.path)' \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let media = try MediaProbe.metadata(source, ffprobe: ffprobe.path)
        let frames = try TemporalExtractor.extract(source: source, media: media, times: [0, 0.10001, 0.10002, 1, 3.5],
                                                   destinationDirectory: directory.appendingPathComponent("sparse-group"), maximumWidth: nil, ffmpegPath: wrapper.path)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "call\n")
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[1].ptsSeconds, 4.0 / 30, accuracy: 0.000_001)
        XCTAssertNil(frames[1].localOrdinal)
    }

    func testDenseVFRPreservesSourceTimeBaseWhenNominalRateIsSlower() throws {
        let source = directory.appendingPathComponent("vfr-24-to-60.mkv")
        try encode([
            "-f", "lavfi", "-i", "testsrc2=s=160x90:r=24:d=6",
            "-f", "lavfi", "-i", "testsrc2=s=160x90:r=60:d=6",
            "-filter_complex", "[0:v]settb=AVTB[v0];[1:v]settb=AVTB[v1];[v0][v1]concat=n=2:v=1:a=0[v]",
            "-map", "[v]", "-fps_mode", "vfr", "-c:v", "libx264", "-preset", "ultrafast",
            "-g", "300", "-keyint_min", "300", "-sc_threshold", "0", source.path,
        ])
        let media = try MediaProbe.metadata(source, ffprobe: ffprobe.path)
        XCTAssertEqual(media.realFrameRate, "24/1", "fixture must reproduce the misleading nominal rate")
        let reference = try MediaProbe.probe(source, ffprobe: ffprobe.path)
        let range = 9.9...10.1
        let expected = reference.frames.filter { range.contains($0.ptsSeconds) }
        XCTAssertEqual(expected.count, 13)
        let frames = try TemporalExtractor.extract(source: source, media: media, range: range, every: .frames(1),
                                                   destinationDirectory: directory.appendingPathComponent("vfr-all-frames"),
                                                   maximumWidth: nil, ffmpegPath: ffmpeg.path)
        XCTAssertEqual(frames.count, 13)
        for (index, pair) in zip(frames, expected).enumerated() {
            XCTAssertEqual(pair.0.localOrdinal, index)
            XCTAssertEqual(pair.0.ptsSeconds, pair.1.ptsSeconds, accuracy: 0.000_001)
        }
        try assertPixels(frames, match: expected, source: source)
    }

    func testDuplicatePTSGlobalOrdinalsPreserveDistinctImages() throws {
        let source = directory.appendingPathComponent("duplicates.mkv")
        try encode(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=1", "-vf", "setpts=floor(N/2)/(15*TB)",
                    "-fps_mode", "passthrough", "-c:v", "ffv1", source.path])
        let reference = try MediaProbe.probe(source, ffprobe: ffprobe.path)
        XCTAssertEqual(reference.frames[4].ptsSeconds, reference.frames[5].ptsSeconds)
        let points = [reference.frames[4], reference.frames[5]]
        let frames = try FrameExtractor.extract(source: source, selectedFrames: points, frameIndex: reference.frames,
                                                destinationDirectory: directory.appendingPathComponent("duplicates"), maximumWidth: nil, ffmpegPath: ffmpeg.path)
        try assertPixels(frames.map { TemporalFrame(ptsSeconds: reference.frames[$0.ordinal].ptsSeconds, url: $0.url) },
                         match: points, source: source)
    }

    func testMoreDuplicatePTSFramesThanEncoderThreadsKeepEveryImage() throws {
        let source = directory.appendingPathComponent("four-duplicate-timestamps.mkv")
        try encode(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=1", "-vf", "setpts=floor(N/4)/(7.5*TB)",
                    "-fps_mode", "passthrough", "-c:v", "ffv1", source.path])
        let reference = try MediaProbe.probe(source, ffprobe: ffprobe.path)
        let points = Array(reference.frames[4...7])
        XCTAssertEqual(Set(points.map(\.ptsSeconds)).count, 1)
        let time = points[0].ptsSeconds
        let temporal = try TemporalExtractor.extract(source: source, media: reference.info, range: time...time, every: .frames(1),
                                                     destinationDirectory: directory.appendingPathComponent("temporal-duplicates"),
                                                     maximumWidth: nil, ffmpegPath: ffmpeg.path)
        XCTAssertEqual(temporal.count, 4)
        XCTAssertEqual(temporal.map(\.ptsSeconds), points.map(\.ptsSeconds))
        XCTAssertEqual(temporal.map(\.localOrdinal), [0, 1, 2, 3])
        try assertPixels(temporal, match: points, source: source)

        let global = try FrameExtractor.extract(source: source, selectedFrames: points, frameIndex: reference.frames,
                                                destinationDirectory: directory.appendingPathComponent("global-duplicates"),
                                                maximumWidth: nil, ffmpegPath: ffmpeg.path, media: reference.info)
        XCTAssertEqual(global.count, 4)
        try assertPixels(global.map { TemporalFrame(ptsSeconds: reference.frames[$0.ordinal].ptsSeconds, url: $0.url) },
                         match: points, source: source)
    }

    func testAnamorphicCircleKeepsDisplayProportionsIncludingRotation() throws {
        let png = directory.appendingPathComponent("anamorphic-circle.png")
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 720, height: 576, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 720, height: 576))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        // Coded pixels are 16/15 wider than high. The stored ellipse becomes a
        // round circle only when the video sample aspect ratio is respected.
        canvas.fillEllipse(in: CGRect(x: 266.25, y: 188, width: 187.5, height: 200))
        let original = try XCTUnwrap(canvas.makeImage())
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, original, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let source = directory.appendingPathComponent("anamorphic.mkv")
        try encode(["-loop", "1", "-i", png.path, "-vf", "setsar=16/15", "-frames:v", "1", "-c:v", "ffv1", source.path])
        let media = try MediaProbe.metadata(source, ffprobe: ffprobe.path)
        XCTAssertEqual(media.width, 768)
        XCTAssertEqual(media.height, 576)
        let frame = try TemporalExtractor.extract(source: source, media: media, times: [media.firstPTS],
                                                  destinationDirectory: directory.appendingPathComponent("anamorphic-frames"), maximumWidth: 1_000,
                                                  ffmpegPath: ffmpeg.path)[0]
        let reference = directory.appendingPathComponent("anamorphic-reference.jpg")
        try encode(["-i", source.path, "-vf", "scale=768:576:flags=lanczos,setsar=1", "-frames:v", "1", "-q:v", "2", reference.path])
        XCTAssertEqual(try Data(contentsOf: frame.url), try Data(contentsOf: reference))
        let circle = try brightBounds(frame.url)
        XCTAssertEqual(circle.width, circle.height, accuracy: 2)

        // MP4 carries a display matrix as well as anamorphic pixel geometry.
        let encoded = directory.appendingPathComponent("anamorphic.mp4")
        try encode(["-i", source.path, "-c:v", "libx264", "-pix_fmt", "yuv420p", encoded.path])
        let rotated = directory.appendingPathComponent("anamorphic-rotated.mp4")
        try encode(["-display_rotation", "90", "-i", encoded.path, "-c", "copy", rotated.path])
        let portrait = try MediaProbe.metadata(rotated, ffprobe: ffprobe.path)
        XCTAssertEqual(portrait.width, 576)
        XCTAssertEqual(portrait.height, 768)
        let rotatedFrame = try TemporalExtractor.extract(source: rotated, media: portrait, times: [portrait.firstPTS],
                                                         destinationDirectory: directory.appendingPathComponent("anamorphic-portrait"), maximumWidth: 1_000,
                                                         ffmpegPath: ffmpeg.path)[0]
        let rotatedCircle = try brightBounds(rotatedFrame.url)
        XCTAssertEqual(rotatedCircle.width, rotatedCircle.height, accuracy: 2)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(rotatedFrame.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 576)
        XCTAssertEqual(image.height, 768)
    }

    func testNonzeroContainerAndTransportStreamTimelineAndRotatedDimensions() throws {
        let source = directory.appendingPathComponent("offset.mkv")
        try encode(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=3", "-vf", "setpts=PTS+5/TB",
                    "-c:v", "libx264", "-g", "90", source.path])
        let media = try MediaProbe.metadata(source, ffprobe: ffprobe.path)
        let reference = try MediaProbe.probe(source, ffprobe: ffprobe.path)
        XCTAssertEqual(media.firstPTS, 5, accuracy: 0.000_001)
        XCTAssertEqual(media.durationSeconds, 3, accuracy: 0.01)
        let selected = [reference.frames[61]]
        let frame = try TemporalExtractor.extract(source: source, media: media, times: selected.map(\.ptsSeconds),
                                                  destinationDirectory: directory.appendingPathComponent("offset-frame"), maximumWidth: nil, ffmpegPath: ffmpeg.path)
        try assertPixels(frame, match: selected, source: source)

        let transport = directory.appendingPathComponent("offset.ts")
        try encode(["-i", source.path, "-c", "copy", "-output_ts_offset", "5", transport.path])
        let transportMedia = try MediaProbe.metadata(transport, ffprobe: ffprobe.path)
        XCTAssertEqual(transportMedia.durationSeconds, 3, accuracy: 0.1)

        let rotated = directory.appendingPathComponent("rotated.mp4")
        try encode(["-display_rotation", "90", "-i", source.path, "-c", "copy", rotated.path])
        let portrait = try MediaProbe.metadata(rotated, ffprobe: ffprobe.path)
        XCTAssertEqual(portrait.width, 90)
        XCTAssertEqual(portrait.height, 160)
        let image = try TemporalExtractor.extract(source: rotated, media: portrait, times: [portrait.firstPTS],
                                                  destinationDirectory: directory.appendingPathComponent("portrait"), maximumWidth: 160, ffmpegPath: ffmpeg.path)[0]
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(image.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 90)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 160)
    }

    private func encode(_ arguments: [String]) throws {
        try ProcessRunner.run(ffmpeg.path, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin"]
                              + MediaResourcePolicy.filterArguments + MediaResourcePolicy.decoderArguments
                              + Array(arguments.dropLast()) + MediaResourcePolicy.encoderArguments + [arguments.last!], timeout: 30)
            .requireSuccess("fixture or reference decode failed")
    }

    private func brightBounds(_ url: URL) throws -> (width: Double, height: Double) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var left = image.width, right = 0, top = image.height, bottom = 0
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[(y * image.width + x) * 4] > 200 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThan(right, left)
        return (Double(right - left + 1), Double(bottom - top + 1))
    }

    /// The reference decodes from the true beginning and selects a GLOBAL n,
    /// using a separate process without seeking or any TemporalExtractor logic.
    private func assertPixels(_ frames: [TemporalFrame], match points: [FramePoint], source: URL) throws {
        XCTAssertEqual(frames.count, points.count)
        for (frame, point) in zip(frames, points) {
            let output = directory.appendingPathComponent("reference-\(UUID().uuidString).jpg")
            try encode(["-i", source.path, "-vf", "select=eq(n\\,\(point.ordinal))", "-frames:v", "1",
                        "-fps_mode", "passthrough", "-q:v", "2", output.path])
            XCTAssertEqual(try Data(contentsOf: frame.url), try Data(contentsOf: output), "wrong pixels for ordinal \(point.ordinal), PTS \(point.ptsSeconds)")
        }
    }
}
