import Foundation

public enum CutReason: String, Codable, Sendable, Equatable {
    case silence = "silence"
    case filler = "filler"
    case ngRepeat = "ng_repeat"
    case manual = "manual"

    public var labelZh: String {
        switch self {
        case .silence: return "静音气口"
        case .filler: return "口癖词"
        case .ngRepeat: return "NG 重录"
        case .manual: return "手动划除"
        }
    }
}

public struct WordToken: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double
    public var autoCutReason: CutReason?
    public var userOverrideKeep: Bool? // true = force keep, false = force cut, nil = follow auto

    public init(
        id: UUID = UUID(),
        text: String,
        start: Double,
        end: Double,
        confidence: Double = 1.0,
        autoCutReason: CutReason? = nil,
        userOverrideKeep: Bool? = nil
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = max(start, end)
        self.confidence = confidence
        self.autoCutReason = autoCutReason
        self.userOverrideKeep = userOverrideKeep
    }

    public var duration: Double {
        max(0, end - start)
    }

    public var isPunctuationOnly: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let punct = CharacterSet.punctuationCharacters.union(.symbols)
        return trimmed.unicodeScalars.allSatisfy { punct.contains($0) }
    }

    public func effectiveCutReason(
        removeFillers: Bool,
        removeNGRepeats: Bool
    ) -> CutReason? {
        if let override = userOverrideKeep {
            return override ? nil : (autoCutReason ?? .manual)
        }
        guard let reason = autoCutReason else { return nil }
        switch reason {
        case .filler:
            return removeFillers ? .filler : nil
        case .ngRepeat:
            return removeNGRepeats ? .ngRepeat : nil
        case .manual, .silence:
            return reason
        }
    }
}

public struct TranscriptClause: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var tokenIndices: [Int]
    public var start: Double
    public var end: Double
    public var autoReason: CutReason?

    public init(
        id: UUID = UUID(),
        tokenIndices: [Int],
        start: Double,
        end: Double,
        autoReason: CutReason? = nil
    ) {
        self.id = id
        self.tokenIndices = tokenIndices
        self.start = start
        self.end = end
        self.autoReason = autoReason
    }
}

public struct SilenceSpan: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public var duration: Double { max(0, end - start) }

    public init(start: Double, end: Double) {
        self.start = start
        self.end = max(start, end)
    }
}

public struct KeepSegment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sourceStart: Double
    public let sourceEnd: Double
    public let outputStart: Double
    public let outputEnd: Double

    public var duration: Double { max(0, sourceEnd - sourceStart) }

    public init(
        id: UUID = UUID(),
        sourceStart: Double,
        sourceEnd: Double,
        outputStart: Double,
        outputEnd: Double
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.outputStart = outputStart
        self.outputEnd = outputEnd
    }
}

public struct CaptionWordTiming: Codable, Sendable, Equatable {
    public let text: String
    public let outputStart: Double
    public let outputEnd: Double

    public init(text: String, outputStart: Double, outputEnd: Double) {
        self.text = text
        self.outputStart = outputStart
        self.outputEnd = outputEnd
    }
}

public struct CaptionCue: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let index: Int
    public let outputStart: Double
    public let outputEnd: Double
    public let words: [CaptionWordTiming]

    public var plainText: String {
        words.map(\.text).joined()
    }

    public init(
        id: UUID = UUID(),
        index: Int,
        outputStart: Double,
        outputEnd: Double,
        words: [CaptionWordTiming]
    ) {
        self.id = id
        self.index = index
        self.outputStart = outputStart
        self.outputEnd = outputEnd
        self.words = words
    }
}

public struct CutWordConfig: Codable, Sendable, Equatable {
    public var removeSilences: Bool
    public var minSilenceDuration: Double
    public var silenceThresholdDb: Float
    public var breathPaddingSec: Double
    public var removeFillers: Bool
    public var removeNGRepeats: Bool
    public var burnCaptions: Bool
    public var maxCaptionCharsPerLine: Int

    public init(
        removeSilences: Bool = true,
        minSilenceDuration: Double = 0.45,
        silenceThresholdDb: Float = -36.0,
        breathPaddingSec: Double = 0.12,
        removeFillers: Bool = true,
        removeNGRepeats: Bool = true,
        burnCaptions: Bool = true,
        maxCaptionCharsPerLine: Int = 16
    ) {
        self.removeSilences = removeSilences
        self.minSilenceDuration = minSilenceDuration
        self.silenceThresholdDb = silenceThresholdDb
        self.breathPaddingSec = breathPaddingSec
        self.removeFillers = removeFillers
        self.removeNGRepeats = removeNGRepeats
        self.burnCaptions = burnCaptions
        self.maxCaptionCharsPerLine = maxCaptionCharsPerLine
    }
}

public struct EditPlan: Codable, Sendable, Equatable {
    public let originalDuration: Double
    public let outputDuration: Double
    public let keepSegments: [KeepSegment]
    public let captionCues: [CaptionCue]
    public let cutSilenceCount: Int
    public let cutFillerCount: Int
    public let cutNGClauseCount: Int

    public var savedDuration: Double {
        max(0, originalDuration - outputDuration)
    }

    public var savedPercent: Double {
        guard originalDuration > 0.001 else { return 0 }
        return max(0, min(100, (savedDuration / originalDuration) * 100.0))
    }

    public init(
        originalDuration: Double,
        outputDuration: Double,
        keepSegments: [KeepSegment],
        captionCues: [CaptionCue],
        cutSilenceCount: Int,
        cutFillerCount: Int,
        cutNGClauseCount: Int
    ) {
        self.originalDuration = originalDuration
        self.outputDuration = outputDuration
        self.keepSegments = keepSegments
        self.captionCues = captionCues
        self.cutSilenceCount = cutSilenceCount
        self.cutFillerCount = cutFillerCount
        self.cutNGClauseCount = cutNGClauseCount
    }

    public func mapSourceToOutputTime(_ sourceTime: Double) -> Double? {
        for seg in keepSegments {
            if sourceTime >= seg.sourceStart - 0.001 && sourceTime <= seg.sourceEnd + 0.001 {
                let offset = min(max(0, sourceTime - seg.sourceStart), seg.duration)
                return seg.outputStart + offset
            }
        }
        return nil
    }
}

public struct MediaAnalysisResult: Codable, Sendable {
    public let sourcePath: String
    public let duration: Double
    public let waveformPeaks: [Float]
    public let silenceSpans: [SilenceSpan]
    public var tokens: [WordToken]
    public var clauses: [TranscriptClause]

    public init(
        sourcePath: String,
        duration: Double,
        waveformPeaks: [Float],
        silenceSpans: [SilenceSpan],
        tokens: [WordToken],
        clauses: [TranscriptClause]
    ) {
        self.sourcePath = sourcePath
        self.duration = duration
        self.waveformPeaks = waveformPeaks
        self.silenceSpans = silenceSpans
        self.tokens = tokens
        self.clauses = clauses
    }
}
