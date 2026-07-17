import Foundation
import XCTest
@testable import WatchthroughCore

final class TranscriptTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchthrough-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testProviderFixturesRetainWordsSpeakersAndHonestPrecision() throws {
        let mac = try TranscriptNormalizer.macParakeet(Data(
            """
            {
              "ok": true,
              "transcription": {
                "engine": "parakeet-mlx",
                "languageCode": "en",
                "rawTranscript": "Hello world",
                "wordTimestamps": [
                  {"word": "Hello", "startMs": 100, "endMs": 400, "speakerId": "speaker_0"},
                  {"word": " ", "startMs": 400, "endMs": 450, "type": "spacing"},
                  {"word": "world", "startMs": 450, "endMs": 900, "speakerId": "speaker_1"}
                ]
              }
            }
            """.utf8
        ))
        XCTAssertEqual(mac.provider, "macparakeet")
        XCTAssertEqual(mac.timingPrecision, .word)
        XCTAssertEqual(mac.text, "Hello world")
        XCTAssertEqual(mac.words.count, 3)
        XCTAssertEqual(mac.words[0].startSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(mac.words[2].speaker, "speaker_1")
        XCTAssertTrue(mac.speakersAvailable)

        let scribe = try TranscriptNormalizer.elevenLabs(Data(
            """
            {
              "language_code": "en",
              "text": "Alpha beta",
              "words": [
                {"text": "Alpha", "start": 0.0, "end": 0.4, "speaker_id": "speaker_0", "logprob": -0.125, "type": "word"},
                {"text": " ", "start": 0.4, "end": 0.5, "type": "spacing"},
                {"text": "beta", "start": 0.5, "end": 0.9, "speaker_id": "speaker_0", "type": "word"}
              ]
            }
            """.utf8
        ))
        XCTAssertEqual(scribe.provider, "elevenlabs")
        XCTAssertEqual(scribe.model, "scribe_v2")
        XCTAssertEqual(scribe.timingPrecision, .word)
        XCTAssertEqual(scribe.words.count, 3)
        XCTAssertEqual(scribe.words.last!.endSeconds, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(scribe.words[0].providerScore, -0.125)
        XCTAssertEqual(scribe.words[0].providerScoreKind, "logprob")
    }

    func testNormalizerDowngradesIncompleteTimedCoverage() throws {
        let transcript = try TranscriptNormalizer.elevenLabs(Data(
            """
            {
              "text": "No spoken word may disappear.",
              "words": [
                {"text": "No", "start": 0.0, "end": 0.2},
                {"text": "spoken", "start": 0.2, "end": 0.4},
                {"text": "may", "start": 0.6, "end": 0.7},
                {"text": "disappear.", "start": 0.7, "end": 1.0}
              ]
            }
            """.utf8
        ))

        XCTAssertEqual(transcript.timingPrecision, .none)
        XCTAssertTrue(transcript.warnings.contains { $0.contains("did not cover") })
    }

    func testReadableTranscriptUsesCompleteTimedSegments() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .segment,
            text: "First complete sentence. Second complete sentence.",
            segments: [
                TranscriptSegment(
                    id: "s1",
                    text: "First complete\n sentence.",
                    startSeconds: 1.25,
                    endSeconds: 2.5,
                    timingSource: "fixture"
                ),
                TranscriptSegment(
                    id: "s2",
                    text: "Second complete sentence.",
                    startSeconds: 2.5,
                    endSeconds: 4,
                    timingSource: "fixture"
                ),
            ]
        )
        let output = temporaryDirectory.appendingPathComponent("segments.txt")

        try TranscriptFiles.writeText(transcript, to: output)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            """
            [00:01.250 --> 00:02.500] First complete sentence.
            [00:02.500 --> 00:04.000] Second complete sentence.

            """
        )
    }

    func testReadableTranscriptGroupsAllWordTokensIntoTimestampedSentences() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .word,
            text: "Hello world. Every token remains!",
            words: [
                TranscriptWord(id: "w1", text: "Hello", startSeconds: 0.1, endSeconds: 0.4),
                TranscriptWord(id: "w2", text: " ", startSeconds: 0.4, endSeconds: 0.45, type: .spacing),
                TranscriptWord(id: "w3", text: "world", startSeconds: 0.45, endSeconds: 0.8),
                TranscriptWord(id: "w4", text: ".", startSeconds: 0.8, endSeconds: 0.85),
                TranscriptWord(id: "w5", text: " ", startSeconds: 0.85, endSeconds: 0.9, type: .spacing),
                TranscriptWord(id: "w6", text: "Every", startSeconds: 0.9, endSeconds: 1.2),
                TranscriptWord(id: "w7", text: "token", startSeconds: 1.2, endSeconds: 1.5),
                TranscriptWord(id: "w8", text: "remains!", startSeconds: 1.5, endSeconds: 1.9),
            ]
        )
        let output = temporaryDirectory.appendingPathComponent("words.txt")

        try TranscriptFiles.writeText(transcript, to: output)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            """
            [00:00.100 --> 00:00.850] Hello world.
            [00:00.900 --> 00:01.900] Every token remains!

            """
        )
    }

    func testReadableTranscriptPrefersCompleteWordStreamOverPartialSegments() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .word,
            text: "Complete 4,000 word stream.",
            words: [
                TranscriptWord(id: "w1", text: "Complete", startSeconds: 0.1, endSeconds: 0.4),
                TranscriptWord(id: "w2", text: "4,000", startSeconds: 0.4, endSeconds: 0.6),
                TranscriptWord(id: "w3", text: "word", startSeconds: 0.6, endSeconds: 0.8),
                TranscriptWord(id: "w4", text: "stream.", startSeconds: 0.8, endSeconds: 1),
            ],
            segments: [
                TranscriptSegment(
                    id: "s1",
                    text: "Partial segment",
                    startSeconds: 0.1,
                    endSeconds: 0.4,
                    timingSource: "fixture"
                ),
            ]
        )
        let output = temporaryDirectory.appendingPathComponent("complete-words.txt")

        try TranscriptFiles.writeText(transcript, to: output)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "[00:00.100 --> 00:01.000] Complete 4,000 word stream.\n"
        )
    }

    func testReadableTranscriptFallsBackToCompleteTextWhenTimedWordIsMissing() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .word,
            text: "No spoken word may disappear.",
            words: [
                TranscriptWord(id: "w1", text: "No", startSeconds: 0.1, endSeconds: 0.2),
                TranscriptWord(id: "w2", text: "spoken", startSeconds: 0.2, endSeconds: 0.4),
                TranscriptWord(id: "w3", text: "may", startSeconds: 0.6, endSeconds: 0.7),
                TranscriptWord(id: "w4", text: "disappear.", startSeconds: 0.7, endSeconds: 1),
            ]
        )
        let output = temporaryDirectory.appendingPathComponent("missing-word.txt")

        try TranscriptFiles.writeText(transcript, to: output)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "[untimed]\nNo spoken word may disappear.\n"
        )
    }

    func testReadableTranscriptDoesNotInventGroupTimingAroundInvalidWord() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .none,
            text: "Every word remains honestly untimed.",
            words: [
                TranscriptWord(id: "w1", text: "Every", startSeconds: 0, endSeconds: 0.2),
                TranscriptWord(id: "w2", text: "word", startSeconds: 0.5, endSeconds: 0.3),
                TranscriptWord(id: "w3", text: "remains", startSeconds: 0.5, endSeconds: 0.7),
                TranscriptWord(id: "w4", text: "honestly", startSeconds: 0.7, endSeconds: 0.9),
                TranscriptWord(id: "w5", text: "untimed.", startSeconds: 0.9, endSeconds: 1),
            ]
        )
        let output = temporaryDirectory.appendingPathComponent("invalid-word-time.txt")

        try TranscriptFiles.writeText(transcript, to: output)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "[untimed]\nEvery word remains honestly untimed.\n"
        )
    }

    func testReadableTranscriptFallsBackToCompleteTextWhenTimedSegmentIsMissing() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .segment,
            text: "First complete sentence. Missing sentence.",
            segments: [
                TranscriptSegment(
                    id: "s1",
                    text: "First complete sentence.",
                    startSeconds: 0.1,
                    endSeconds: 1,
                    timingSource: "fixture"
                ),
            ]
        )
        let output = temporaryDirectory.appendingPathComponent("missing-segment.txt")

        try TranscriptFiles.writeText(transcript, to: output)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "[untimed]\nFirst complete sentence. Missing sentence.\n"
        )
    }

    func testReadableTranscriptPreservesCompleteUntimedTextAndLabelsIt() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .none,
            text: "Everything   remains\ncomplete and clearly untimed."
        )
        let output = temporaryDirectory.appendingPathComponent("untimed.txt")

        try TranscriptFiles.writeText(transcript, to: output)

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            """
            [untimed]
            Everything remains complete and clearly untimed.

            """
        )
    }

    func testSRTIsSegmentPreciseAndCaptionBoundariesDoNotDuplicateWords() throws {
        let captions = temporaryDirectory.appendingPathComponent("fixture.srt")
        try Data(
            """
            1
            00:00:00,000 --> 00:00:01,000
            First &amp; <i>caption</i>

            2
            00:00:01,000 --> 00:00:02,250
            Second caption

            """.utf8
        ).write(to: captions)
        let transcript = try TranscriptSidecar.load(captions)
        XCTAssertEqual(transcript.timingPrecision, .segment)
        XCTAssertTrue(transcript.words.isEmpty)
        XCTAssertEqual(transcript.segments.map(\.startSeconds), [0, 1])
        XCTAssertEqual(transcript.segments.last?.endSeconds, 2.25)
        XCTAssertEqual(transcript.segments.first?.text, "First & caption")

        let timedWords = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .word,
            text: "left boundary",
            words: [
                TranscriptWord(id: "w1", text: "left", startSeconds: 0.2, endSeconds: 0.4),
                TranscriptWord(id: "w2", text: "boundary", startSeconds: 0.9, endSeconds: 1.1),
            ]
        )
        let cells = [
            packetCell(index: 0, start: 0, end: 1),
            packetCell(index: 1, start: 1, end: 2),
        ]
        let assigned = TranscriptCaptions.assign(timedWords, to: cells)
        XCTAssertEqual(assigned[0].caption, "left")
        XCTAssertEqual(assigned[1].caption, "boundary")
    }

    func testCaptionAssignmentHonorsAggregateTimingPrecision() throws {
        let transcript = CanonicalTranscript(
            provider: "mixed-fixture",
            timingPrecision: .none,
            text: "Timed but not wholly authoritative",
            segments: [
                TranscriptSegment(
                    id: "s1",
                    text: "Timed",
                    startSeconds: 0,
                    endSeconds: 1,
                    timingSource: "fixture"
                ),
                TranscriptSegment(id: "s2", text: "Untimed", timingSource: "fixture")
            ]
        )
        let assigned = TranscriptCaptions.assign(
            transcript,
            to: [packetCell(index: 0, start: 0, end: 1)]
        )
        XCTAssertEqual(assigned[0].caption, "")
    }

    func testMediaRelativeTranscriptCanAlignToNonzeroDecodedPTS() throws {
        let transcript = CanonicalTranscript(
            provider: "fixture",
            timingPrecision: .word,
            text: "At the cut",
            words: [
                TranscriptWord(
                    id: "w1",
                    text: "At the cut",
                    startSeconds: 1.8,
                    endSeconds: 2.2
                )
            ]
        )
        let aligned = TranscriptTimeline.alignedToDecodedPTS(transcript, firstPTS: 5)
        XCTAssertEqual(aligned.words[0].startSeconds, 6.8, accuracy: 0.000_001)
        XCTAssertEqual(aligned.words[0].endSeconds, 7.2, accuracy: 0.000_001)
        XCTAssertTrue(aligned.warnings.contains { $0.contains("+5") })

        let assigned = TranscriptCaptions.assign(
            aligned,
            to: [
                packetCell(index: 0, start: 5, end: 6.5),
                packetCell(index: 1, start: 6.5, end: 7.5),
            ]
        )
        XCTAssertEqual(assigned[0].caption, "")
        XCTAssertEqual(assigned[1].caption, "At the cut")
    }

    func testRollingVTTUsesInlineWordTimingWithoutRepeatingPriorLines() throws {
        let captions = temporaryDirectory.appendingPathComponent("rolling.vtt")
        try Data(
            """
            WEBVTT
            Language: en

            00:00:00.000 --> 00:00:01.000
            when<00:00:00.200><c> it</c><00:00:00.500><c> comes</c>

            00:00:01.000 --> 00:00:01.010
            when it comes

            00:00:01.010 --> 00:00:02.000
            when it comes
            Roblox<00:00:01.400><c> Studio</c>

            """.utf8
        ).write(to: captions)

        let transcript = try TranscriptSidecar.load(captions)
        XCTAssertEqual(transcript.timingPrecision, .word)
        XCTAssertEqual(transcript.language, "en")
        XCTAssertEqual(transcript.text, "when it comes Roblox Studio")
        XCTAssertEqual(transcript.words.map(\.text), ["when", "it", "comes", "Roblox", "Studio"])
        XCTAssertEqual(transcript.words[0].startSeconds, 0, accuracy: 0.000_001)
        XCTAssertEqual(transcript.words[3].startSeconds, 1.01, accuracy: 0.000_001)
        XCTAssertEqual(transcript.words[4].startSeconds, 1.4, accuracy: 0.000_001)
    }

    func testMixedVTTKeepsOrdinaryCuesAndDowngradesAggregatePrecision() throws {
        let captions = temporaryDirectory.appendingPathComponent("mixed.vtt")
        try Data(
            """
            WEBVTT

            00:00:00.000 --> 00:00:01.000
            Hello<00:00:00.400><c> world</c>

            00:00:01.000 --> 00:00:02.000
            This ordinary cue must remain

            """.utf8
        ).write(to: captions)

        let transcript = try TranscriptSidecar.load(captions)
        XCTAssertEqual(transcript.timingPrecision, .segment)
        XCTAssertTrue(transcript.words.isEmpty)
        XCTAssertEqual(transcript.segments.map(\.text), ["Hello world", "This ordinary cue must remain"])
        XCTAssertTrue(transcript.text.contains("This ordinary cue must remain"))
        XCTAssertTrue(transcript.warnings.contains { $0.contains("Mixed WebVTT") })
    }

    func testNamedAdapterUsesDirectArgumentPlaceholders() throws {
        let input = temporaryDirectory.appendingPathComponent("input with spaces.json")
        let output = temporaryDirectory.appendingPathComponent("output with spaces.json")
        let config = temporaryDirectory.appendingPathComponent("config.json")
        let transcript = CanonicalTranscript(
            provider: "fixture-command",
            timingPrecision: .none,
            text: "Copied without shell parsing"
        )
        try StableJSON.write(transcript, to: input)
        try StableJSON.write(
            WatchthroughUserConfig(transcribers: [
                "copy": NamedTranscriptAdapterDefinition(
                    argv: ["/bin/cp", "{input}", "{output}"]
                ),
            ]),
            to: config
        )

        let result = try NamedTranscriptAdapter.transcribe(
            name: "copy",
            input: input,
            output: output,
            configURL: config,
            timeout: 5
        )
        XCTAssertEqual(result.transcript.provider, "fixture-command")
        XCTAssertEqual(result.transcript.text, "Copied without shell parsing")
        XCTAssertEqual(result.rawResponse, try Data(contentsOf: input))
    }

    func testMacParakeetProbeIsPrivateAndNeverRequestsUncachedSpeakerModels() throws {
        let executable = temporaryDirectory.appendingPathComponent("macparakeet-fixture.sh")
        let log = temporaryDirectory.appendingPathComponent("macparakeet-invocations.txt")
        let script = """
        #!/bin/sh
        printf '%s|%s|%s\n' "${MACPARAKEET_TELEMETRY-unset}" "${DO_NOT_TRACK-unset}" "$*" >> '\(log.path)'
        if [ "$1" = "health" ]; then
          printf '%s\n' '{"speechStack":{"speechModelCached":true,"speakerModelsCached":false}}'
          exit 0
        fi
        if [ "$1" = "--version" ]; then
          printf '%s\n' 'fixture-1.0'
          exit 0
        fi
        if [ "$1" = "transcribe" ] && [ "$2" = "--help" ]; then
          printf '%s\n' '--speaker-detection'
          exit 0
        fi
        if [ "$1" = "transcribe" ]; then
          printf '%s\n' 'CoreML diagnostic {not-json}'
          printf '%s\n' '{"ok":true,"transcription":{"engine":"fixture","rawTranscript":"Private","wordTimestamps":[{"word":"Private","startMs":0,"endMs":500}]}}'
          exit 0
        fi
        exit 1
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let input = temporaryDirectory.appendingPathComponent("audio.wav")
        try Data("fixture".utf8).write(to: input)

        let capability = MacParakeetTranscriber.probe(executable: executable.path)
        XCTAssertTrue(capability.available)
        XCTAssertTrue(capability.supportsSpeakerDetection)
        XCTAssertFalse(capability.speakerModelsCached)

        let run = try MacParakeetTranscriber.transcribe(
            input: input,
            executable: executable.path,
            timeout: 5
        )
        XCTAssertTrue(String(decoding: run.rawResponse, as: UTF8.self).hasPrefix("CoreML diagnostic {not-json}\n"))
        XCTAssertTrue(run.transcript.warnings.contains {
            $0.contains("diagnostic prefix") && $0.contains("raw stdout was preserved unchanged")
        })
        XCTAssertTrue(run.transcript.warnings.contains { $0.contains("local models") })
        let invocations = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertTrue(invocations.allSatisfy { $0.hasPrefix("0|1|") })
        XCTAssertTrue(invocations.contains { $0.contains("--speaker-detection off") })
        let transcription = try XCTUnwrap(invocations.last { line in
            line.contains("transcribe \(input.path)")
        })
        XCTAssertTrue(transcription.contains("--engine parakeet"))
        let arguments = transcription.split(separator: " ").map(String.init)
        let databaseFlag = try XCTUnwrap(arguments.firstIndex(of: "--database"))
        let database = arguments[databaseFlag + 1]
        XCTAssertTrue(database.contains("watchthrough-macparakeet-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database))
    }

    func testNamedAdapterTimeoutAndMalformedOutputFailWithoutEchoingInput() throws {
        let input = temporaryDirectory.appendingPathComponent("private-input.json")
        let output = temporaryDirectory.appendingPathComponent("adapter-output.json")
        let config = temporaryDirectory.appendingPathComponent("config-errors.json")
        try Data("fixture-private-marker".utf8).write(to: input)

        try StableJSON.write(
            WatchthroughUserConfig(transcribers: [
                "malformed": NamedTranscriptAdapterDefinition(
                    argv: ["/bin/cp", "{input}", "{output}"]
                ),
            ]),
            to: config
        )
        XCTAssertThrowsError(
            try NamedTranscriptAdapter.transcribe(
                name: "malformed",
                input: input,
                output: output,
                configURL: config,
                timeout: 2
            )
        ) { error in
            XCTAssertFalse(String(describing: error).contains("fixture-private-marker"))
        }

        let spinner = temporaryDirectory.appendingPathComponent("spinner.sh")
        try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: spinner)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: spinner.path
        )
        try StableJSON.write(
            WatchthroughUserConfig(transcribers: [
                "timeout": NamedTranscriptAdapterDefinition(
                    argv: [spinner.path, "{input}", "{output}"]
                ),
            ]),
            to: config
        )
        XCTAssertThrowsError(
            try NamedTranscriptAdapter.transcribe(
                name: "timeout",
                input: input,
                output: output,
                configURL: config,
                timeout: 0.05
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("timed out"))
            XCTAssertFalse(String(describing: error).contains("fixture-private-marker"))
        }
    }

    func testScribeAdapterUsesMultipartUploadWithoutRealNetwork() throws {
        let audio = temporaryDirectory.appendingPathComponent("fixture.wav")
        try Data("RIFF-fixture-audio".utf8).write(to: audio)
        let rawResponse = temporaryDirectory.appendingPathComponent("scribe-response.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScribeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            ScribeURLProtocol.reset()
        }

        let response = Data(
            """
            {
              "language_code": "en",
              "text": "Fixture",
              "words": [
                {"text": "Fixture", "start": 0.0, "end": 0.5, "type": "word"}
              ]
            }
            """.utf8
        )
        ScribeURLProtocol.prepare(response: response)
        let credential = SecretCredential(value: "fixture-key", origin: .environment)
        let run = try ElevenLabsScribeV2.transcribe(
            audio: audio,
            credential: credential,
            rawResponseURL: rawResponse,
            endpoint: URL(string: "https://watchthrough.invalid/scribe")!,
            timeout: 5,
            temporaryDirectory: temporaryDirectory,
            session: session
        )

        XCTAssertEqual(run.transcript.provider, "elevenlabs")
        XCTAssertEqual(run.transcript.timingPrecision, .word)
        XCTAssertEqual(try Data(contentsOf: rawResponse), response)
        let request = try XCTUnwrap(ScribeURLProtocol.capturedRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://watchthrough.invalid/scribe")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "fixture-key")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=watchthrough-") == true
        )
        let body = try XCTUnwrap(ScribeURLProtocol.capturedBody())
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"model_id\""))
        XCTAssertTrue(bodyText.contains("scribe_v2"))
        XCTAssertTrue(bodyText.contains("name=\"timestamps_granularity\""))
        XCTAssertTrue(bodyText.contains("word"))
        XCTAssertTrue(bodyText.contains("RIFF-fixture-audio"))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("watchthrough-scribe-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    private func packetCell(index: Int, start: Double, end: Double) -> PacketCell {
        PacketCell(
            index: index,
            ordinal: index,
            ptsSeconds: (start + end) / 2,
            intervalStartSeconds: start,
            intervalEndSeconds: end,
            timestamp: CLIParser.formatTime((start + end) / 2),
            caption: "",
            framePath: "frame-\(index).jpg"
        )
    }
}

private final class ScribeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var recordedRequest: URLRequest?
    private static var recordedBody: Data?

    static func prepare(response: Data) {
        lock.lock()
        responseData = response
        recordedRequest = nil
        recordedBody = nil
        lock.unlock()
    }

    static func reset() {
        prepare(response: Data())
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }

    static func capturedBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return recordedBody
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readAll)
        Self.lock.lock()
        Self.recordedRequest = request
        Self.recordedBody = body
        let responseData = Self.responseData
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
