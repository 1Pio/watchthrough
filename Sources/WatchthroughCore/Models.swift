import Foundation

public enum WatchthroughVersion {
    public static let current = "0.1.0"
    public static let resultSchema = "watchthrough.result.v1"
    public static let manifestSchema = "watchthrough.manifest.v1"
    public static let transcriptSchema = "watchthrough.transcript.v1"
    public static let packetSchema = "watchthrough.packet.v1"
}

public enum WatchthroughExit: Int32 {
    case success = 0
    case usage = 2
    case readiness = 3
    case operation = 4
}

public struct WatchthroughFailure: Error, CustomStringConvertible {
    public let category: WatchthroughExit
    public let message: String

    public init(_ category: WatchthroughExit, _ message: String) {
        self.category = category
        self.message = message
    }

    public var description: String { message }
}

public enum TimingPrecision: String, Codable, Sendable {
    case word
    case segment
    case none
}

public enum TranscriptTokenType: String, Codable, Sendable {
    case word
    case spacing
    case audioEvent = "audio_event"
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var speaker: String?
    public var confidence: Double?
    public var providerScore: Double?
    public var providerScoreKind: String?
    public var type: TranscriptTokenType

    public init(
        id: String,
        text: String,
        startSeconds: Double,
        endSeconds: Double,
        speaker: String? = nil,
        confidence: Double? = nil,
        providerScore: Double? = nil,
        providerScoreKind: String? = nil,
        type: TranscriptTokenType = .word
    ) {
        self.id = id
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speaker = speaker
        self.confidence = confidence
        self.providerScore = providerScore
        self.providerScoreKind = providerScoreKind
        self.type = type
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var speaker: String?
    public var timingSource: String

    public init(
        id: String,
        text: String,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        speaker: String? = nil,
        timingSource: String
    ) {
        self.id = id
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speaker = speaker
        self.timingSource = timingSource
    }
}

public struct CanonicalTranscript: Codable, Equatable, Sendable {
    public var schema: String
    public var provider: String
    public var model: String?
    public var language: String?
    public var timingPrecision: TimingPrecision
    public var speakersAvailable: Bool
    public var text: String
    public var words: [TranscriptWord]
    public var segments: [TranscriptSegment]
    public var warnings: [String]

    public init(
        provider: String,
        model: String? = nil,
        language: String? = nil,
        timingPrecision: TimingPrecision,
        speakersAvailable: Bool = false,
        text: String,
        words: [TranscriptWord] = [],
        segments: [TranscriptSegment] = [],
        warnings: [String] = []
    ) {
        self.schema = WatchthroughVersion.transcriptSchema
        self.provider = provider
        self.model = model
        self.language = language
        self.timingPrecision = timingPrecision
        self.speakersAvailable = speakersAvailable
        self.text = text
        self.words = words
        self.segments = segments
        self.warnings = warnings
    }
}

public struct FramePoint: Codable, Equatable, Sendable {
    public var ordinal: Int
    public var ptsSeconds: Double

    public init(ordinal: Int, ptsSeconds: Double) {
        self.ordinal = ordinal
        self.ptsSeconds = ptsSeconds
    }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var codec: String?
    public var pixelFormat: String?
    public var averageFrameRate: String?
    public var realFrameRate: String?
    public var timeBase: String?
    public var hasAudio: Bool
    public var frameCount: Int
    public var firstPTS: Double
    public var lastPTS: Double

    public init(
        durationSeconds: Double,
        width: Int,
        height: Int,
        codec: String? = nil,
        pixelFormat: String? = nil,
        averageFrameRate: String? = nil,
        realFrameRate: String? = nil,
        timeBase: String? = nil,
        hasAudio: Bool,
        frameCount: Int,
        firstPTS: Double,
        lastPTS: Double
    ) {
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.codec = codec
        self.pixelFormat = pixelFormat
        self.averageFrameRate = averageFrameRate
        self.realFrameRate = realFrameRate
        self.timeBase = timeBase
        self.hasAudio = hasAudio
        self.frameCount = frameCount
        self.firstPTS = firstPTS
        self.lastPTS = lastPTS
    }
}

public struct SourceRecord: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var sizeBytes: Int64
    public var modifiedAt: String

    public init(path: String, sha256: String, sizeBytes: Int64, modifiedAt: String) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct PreparationConfig: Codable, Equatable, Sendable {
    public var transcriber: String
    public var transcriptInputFingerprint: String
    public var visualSampleLimit: Int

    public init(
        transcriber: String,
        transcriptInputFingerprint: String = "unspecified",
        visualSampleLimit: Int = 7_200
    ) {
        self.transcriber = transcriber
        self.transcriptInputFingerprint = transcriptInputFingerprint
        self.visualSampleLimit = visualSampleLimit
    }

    private enum CodingKeys: String, CodingKey {
        case transcriber
        case transcriptInputFingerprint
        case visualSampleLimit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transcriber = try values.decode(String.self, forKey: .transcriber)
        transcriptInputFingerprint = try values.decodeIfPresent(
            String.self,
            forKey: .transcriptInputFingerprint
        ) ?? "unspecified"
        visualSampleLimit = try values.decodeIfPresent(
            Int.self,
            forKey: .visualSampleLimit
        ) ?? 7_200
    }
}

public struct TranscriptSummary: Codable, Equatable, Sendable {
    public var available: Bool
    public var provider: String?
    public var model: String?
    public var language: String?
    public var timingPrecision: TimingPrecision
    public var speakersAvailable: Bool?
    public var path: String?
    public var textPath: String?
    public var rawPath: String?

    public init(
        available: Bool,
        provider: String? = nil,
        model: String? = nil,
        language: String? = nil,
        timingPrecision: TimingPrecision = .none,
        speakersAvailable: Bool? = nil,
        path: String? = nil,
        textPath: String? = nil,
        rawPath: String? = nil
    ) {
        self.available = available
        self.provider = provider
        self.model = model
        self.language = language
        self.timingPrecision = timingPrecision
        self.speakersAvailable = speakersAvailable
        self.path = path
        self.textPath = textPath
        self.rawPath = rawPath
    }
}

public struct VisualSummary: Codable, Equatable, Sendable {
    public var frameIndexPath: String
    public var overviewPacketPath: String
    public var eventsPath: String
    public var overviewFrames: Int
    public var largestOverviewGapSeconds: Double
    public var eventCount: Int
    public var scanFPS: Double

    public init(
        frameIndexPath: String,
        overviewPacketPath: String,
        eventsPath: String,
        overviewFrames: Int,
        largestOverviewGapSeconds: Double,
        eventCount: Int,
        scanFPS: Double
    ) {
        self.frameIndexPath = frameIndexPath
        self.overviewPacketPath = overviewPacketPath
        self.eventsPath = eventsPath
        self.overviewFrames = overviewFrames
        self.largestOverviewGapSeconds = largestOverviewGapSeconds
        self.eventCount = eventCount
        self.scanFPS = scanFPS
    }
}

public struct PreparationManifest: Codable, Equatable, Sendable {
    public var schema = WatchthroughVersion.manifestSchema
    public var toolVersion = WatchthroughVersion.current
    public var state = "complete"
    public var createdAt: String
    public var completedAt: String
    public var source: SourceRecord
    public var media: MediaInfo
    public var config: PreparationConfig
    public var transcript: TranscriptSummary
    public var visual: VisualSummary
    public var tools: [String: String]
    public var warnings: [String]

    public init(
        createdAt: String,
        completedAt: String,
        source: SourceRecord,
        media: MediaInfo,
        config: PreparationConfig,
        transcript: TranscriptSummary,
        visual: VisualSummary,
        tools: [String: String],
        warnings: [String]
    ) {
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.source = source
        self.media = media
        self.config = config
        self.transcript = transcript
        self.visual = visual
        self.tools = tools
        self.warnings = warnings
    }
}

public struct VisualSample: Codable, Equatable, Sendable {
    public var ptsSeconds: Double
    public var globalChange: Double
    public var regionalChange: Double
    public var outerChange: Double
    public var colorShift: Double
    public var adaptiveScore: Double
    public var fired: Bool
}

public struct VisualEvent: Codable, Equatable, Sendable {
    public var id: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var peakSeconds: Double
    public var peakScore: Double
    public var peakMetric: String
    public var sampleCount: Int
}

public struct EventIndex: Codable, Equatable, Sendable {
    public var schema = "watchthrough.events.v1"
    public var scanFPS: Double
    public var sampleWidth: Int
    public var sampleHeight: Int
    public var samples: [VisualSample]
    public var events: [VisualEvent]

    public init(scanFPS: Double, sampleWidth: Int, sampleHeight: Int, samples: [VisualSample], events: [VisualEvent]) {
        self.scanFPS = scanFPS
        self.sampleWidth = sampleWidth
        self.sampleHeight = sampleHeight
        self.samples = samples
        self.events = events
    }
}

public struct PacketCell: Codable, Equatable, Sendable {
    public var index: Int
    public var ordinal: Int
    public var ptsSeconds: Double
    public var intervalStartSeconds: Double
    public var intervalEndSeconds: Double
    public var timestamp: String
    public var caption: String
    public var framePath: String
}

public struct InspectionPacket: Codable, Equatable, Sendable {
    public var schema = WatchthroughVersion.packetSchema
    public var selector: String
    public var sourcePath: String
    public var rangeStartSeconds: Double
    public var rangeEndSeconds: Double
    public var sampling: String
    public var cellsPerSheet: Int
    public var largestGapSeconds: Double
    public var timingPrecision: TimingPrecision
    public var cells: [PacketCell]
    public var sheets: [String]
    public var warnings: [String]

    public init(
        selector: String,
        sourcePath: String,
        rangeStartSeconds: Double,
        rangeEndSeconds: Double,
        sampling: String,
        cellsPerSheet: Int,
        largestGapSeconds: Double,
        timingPrecision: TimingPrecision,
        cells: [PacketCell],
        sheets: [String],
        warnings: [String] = []
    ) {
        self.selector = selector
        self.sourcePath = sourcePath
        self.rangeStartSeconds = rangeStartSeconds
        self.rangeEndSeconds = rangeEndSeconds
        self.sampling = sampling
        self.cellsPerSheet = cellsPerSheet
        self.largestGapSeconds = largestGapSeconds
        self.timingPrecision = timingPrecision
        self.cells = cells
        self.sheets = sheets
        self.warnings = warnings
    }
}

public enum InspectionSelector: Equatable, Sendable {
    case overview
    case events
    case event(String)
    case time(Double)
    case range(Double, Double)
    case frame(Int)
}

public enum SamplingInterval: Equatable, Sendable {
    case seconds(Double)
    case frames(Int)
}

public struct CommandResult: Codable, Sendable {
    public var schema = WatchthroughVersion.resultSchema
    public var ok: Bool
    public var command: String
    public var analysis: String?
    public var reused: Bool?
    public var artifacts: [String: String]
    public var details: [String: String]
    public var warnings: [String]

    public init(
        ok: Bool,
        command: String,
        analysis: String? = nil,
        reused: Bool? = nil,
        artifacts: [String: String] = [:],
        details: [String: String] = [:],
        warnings: [String] = []
    ) {
        self.ok = ok
        self.command = command
        self.analysis = analysis
        self.reused = reused
        self.artifacts = artifacts
        self.details = details
        self.warnings = warnings
    }
}
