import Testing
import Foundation
import AVFoundation
@testable import CutWordCore

@Suite("CutWord Core Engine & Real Video Pipeline Tests")
struct CutWordTests {

    @Test("Chinese NG repeated bad-take & filler detection marks earlier aborted take")
    func testNGAndFillerDetection() {
        let raw: [WordToken] = [
            // Aborted Take 1: 0.2s .. 1.6s ("今天给大家分享一款")
            WordToken(text: "今", start: 0.20, end: 0.35),
            WordToken(text: "天", start: 0.35, end: 0.50),
            WordToken(text: "给", start: 0.50, end: 0.65),
            WordToken(text: "大", start: 0.65, end: 0.80),
            WordToken(text: "家", start: 0.80, end: 0.95),
            WordToken(text: "分", start: 0.95, end: 1.15),
            WordToken(text: "享", start: 1.15, end: 1.30),
            WordToken(text: "一", start: 1.30, end: 1.45),
            WordToken(text: "款", start: 1.45, end: 1.60),
            // Retake cue: 2.1s .. 2.7s ("不对重来")
            WordToken(text: "不", start: 2.10, end: 2.25),
            WordToken(text: "对", start: 2.25, end: 2.40),
            WordToken(text: "重", start: 2.40, end: 2.55),
            WordToken(text: "来", start: 2.55, end: 2.70),
            // Clean Take 2: 3.4s .. 5.2s ("今天给大家分享一款免费开源工具。")
            WordToken(text: "今", start: 3.40, end: 3.55),
            WordToken(text: "天", start: 3.55, end: 3.70),
            WordToken(text: "给", start: 3.70, end: 3.85),
            WordToken(text: "大", start: 3.85, end: 4.00),
            WordToken(text: "家", start: 4.00, end: 4.15),
            WordToken(text: "分", start: 4.15, end: 4.30),
            WordToken(text: "享", start: 4.30, end: 4.45),
            WordToken(text: "一", start: 4.45, end: 4.55),
            WordToken(text: "款", start: 4.55, end: 4.70),
            WordToken(text: "免", start: 4.70, end: 4.85),
            WordToken(text: "费", start: 4.85, end: 4.95),
            WordToken(text: "工", start: 4.95, end: 5.08),
            WordToken(text: "具", start: 5.08, end: 5.20),
            WordToken(text: "。", start: 5.20, end: 5.25),
            // Filler: 6.1s .. 6.4s ("嗯")
            WordToken(text: "嗯", start: 6.10, end: 6.40),
            // Next sentence: 7.1s .. 8.0s ("非常好用！")
            WordToken(text: "非", start: 7.10, end: 7.30),
            WordToken(text: "常", start: 7.30, end: 7.50),
            WordToken(text: "好", start: 7.50, end: 7.75),
            WordToken(text: "用", start: 7.75, end: 7.95),
            WordToken(text: "！", start: 7.95, end: 8.00),
        ]

        let silences = [
            SilenceSpan(start: 1.60, end: 2.10),
            SilenceSpan(start: 2.70, end: 3.40),
            SilenceSpan(start: 5.25, end: 6.10),
            SilenceSpan(start: 6.40, end: 7.10),
        ]

        let (annotated, clauses) = SmartCutDetector.analyzeTranscript(
            tokens: raw,
            duration: 8.5,
            silenceSpans: silences
        )

        #expect(clauses.count == 5)
        #expect(clauses[0].autoReason == .ngRepeat)
        #expect(clauses[1].autoReason == .ngRepeat)
        #expect(clauses[2].autoReason == nil)
        #expect(clauses[3].autoReason == .filler)
        #expect(clauses[4].autoReason == nil)

        let plan = SmartCutDetector.compileEditPlan(
            tokens: annotated,
            clauses: clauses,
            silenceSpans: silences,
            duration: 8.5,
            config: CutWordConfig()
        )

        #expect(plan.cutNGClauseCount == 2)
        #expect(plan.cutFillerCount == 1)
        #expect(plan.outputDuration < 3.6)
        #expect(plan.captionCues.count == 2)
        #expect(plan.captionCues[0].plainText == "今天给大家分享一款免费工具")
        #expect(plan.captionCues[1].plainText == "非常好用")

        let srt = SubtitleExporter.formatSRT(cues: plan.captionCues)
        #expect(srt.contains("00:00:00,"))
        #expect(srt.contains("今天给大家分享一款免费工具"))
        #expect(!srt.contains("不对重来"))
        #expect(!srt.contains("嗯"))

        let fcpxml = SubtitleExporter.formatFCPXML(
            sourceURL: URL(fileURLWithPath: "/tmp/sample.mp4"),
            projectName: "Sample",
            renderWidth: 1280,
            renderHeight: 720,
            plan: plan
        )
        #expect(fcpxml.contains("<!DOCTYPE fcpxml>"))
        #expect(fcpxml.contains("<asset-clip"))
    }

    @Test("Real end-to-end spoken MP4 synthesis, SpeechAnalyzer transcription, cutting & subtitled MP4 export")
    func testRealEndToEndVideoPipeline() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutword-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let rawVideo = tmpDir.appendingPathComponent("raw.mp4")
        _ = try await SampleVideoBuilder.generateBuiltInDemoVideo(to: rawVideo)
        #expect(FileManager.default.fileExists(atPath: rawVideo.path))

        let analysis = try await CutWordPipeline.analyzeMedia(url: rawVideo, localeIdentifier: "zh-CN")
        #expect(analysis.duration > 10.0)
        #expect(!analysis.tokens.isEmpty)
        #expect(!analysis.silenceSpans.isEmpty)

        let plan = SmartCutDetector.compileEditPlan(
            tokens: analysis.tokens,
            clauses: analysis.clauses,
            silenceSpans: analysis.silenceSpans,
            duration: analysis.duration,
            config: CutWordConfig()
        )

        #expect(plan.outputDuration < plan.originalDuration * 0.78)
        #expect(plan.cutSilenceCount >= 3)
        #expect(!plan.captionCues.isEmpty)

        let exportedMP4 = tmpDir.appendingPathComponent("cleaned-subtitled.mp4")
        try await VideoExporter.exportMP4(
            sourceURL: rawVideo,
            destinationURL: exportedMP4,
            plan: plan,
            burnCaptions: true
        )

        let outAsset = AVURLAsset(url: exportedMP4)
        let outDur = try await outAsset.load(.duration).seconds
        #expect(abs(outDur - plan.outputDuration) < 0.35)
    }

    @Test("Legacy SFSpeech weighted timestamp allocation & offline speech model Chinese guidance")
    func testWeightedLegacyTokenAllocationAndOfflineGuidance() {
        let weighted = SpeechEngine.allocateWeightedTokens(
            substring: "导出FCPXML，",
            start: 2.00,
            duration: 1.00,
            confidence: 0.95
        )
        // Should keep "FCPXML" intact rather than splitting into 6 single letters: ["导", "出", "FCPXML", "，"]
        #expect(weighted.map(\.text) == ["导", "出", "FCPXML", "，"])
        #expect(abs(weighted.first!.start - 2.00) < 0.0001)
        #expect(abs(weighted.last!.end - 3.00) < 0.0001)

        let fcpxmlDur = weighted[2].end - weighted[2].start
        let cjkDur = weighted[0].end - weighted[0].start
        let punctDur = weighted[3].end - weighted[3].start
        #expect(fcpxmlDur > cjkDur, "Multi-syllable English acronym should receive more weight than a single CJK character")
        #expect(punctDur <= 0.06, "Trailing comma should be capped so it does not steal speech duration")

        let fakeMissingErr = NSError(
            domain: "kLSRErrorDomain",
            code: 201,
            userInfo: [NSLocalizedDescriptionKey: "On-device Siri and Dictation is disabled"]
        )
        let mapped = SpeechEngine.friendlyRecognitionError(fakeMissingErr, localeIdentifier: "zh-CN")
        let desc = mapped.errorDescription ?? ""
        #expect(desc.contains("系统设置 → 键盘 → 听写"))
    }

    @Test("Expanded 120+ spoken filler, NG retake & homophone lexicon detects creator retakes")
    func testExpandedCreatorLexiconOver120Groups() {
        #expect(SmartCutDetector.totalLexiconGroupCount >= 120)

        let raw: [WordToken] = [
            // Aborted take with homophone typo ("今天实测剪子软件")
            WordToken(text: "今", start: 0.10, end: 0.25),
            WordToken(text: "天", start: 0.25, end: 0.40),
            WordToken(text: "实", start: 0.40, end: 0.55),
            WordToken(text: "测", start: 0.55, end: 0.70),
            WordToken(text: "剪", start: 0.70, end: 0.85),
            WordToken(text: "子", start: 0.85, end: 1.00),
            // New creator retake interjection ("嘴瓢了")
            WordToken(text: "嘴", start: 1.40, end: 1.55),
            WordToken(text: "瓢", start: 1.55, end: 1.70),
            WordToken(text: "了", start: 1.70, end: 1.85),
            // Clean take ("今天实测剪字软件。")
            WordToken(text: "今", start: 2.30, end: 2.45),
            WordToken(text: "天", start: 2.45, end: 2.60),
            WordToken(text: "实", start: 2.60, end: 2.75),
            WordToken(text: "测", start: 2.75, end: 2.90),
            WordToken(text: "剪", start: 2.90, end: 3.05),
            WordToken(text: "字", start: 3.05, end: 3.20),
            WordToken(text: "软", start: 3.20, end: 3.35),
            WordToken(text: "件", start: 3.35, end: 3.50),
            WordToken(text: "。", start: 3.50, end: 3.55),
            // Expanded compound filler ("那个就是")
            WordToken(text: "那", start: 4.00, end: 4.15),
            WordToken(text: "个", start: 4.15, end: 4.30),
            WordToken(text: "就", start: 4.30, end: 4.45),
            WordToken(text: "是", start: 4.45, end: 4.60),
            // Final clean clause ("超快！")
            WordToken(text: "超", start: 5.05, end: 5.25),
            WordToken(text: "快", start: 5.25, end: 5.45),
            WordToken(text: "！", start: 5.45, end: 5.50),
        ]

        let silences = [
            SilenceSpan(start: 1.00, end: 1.40),
            SilenceSpan(start: 1.85, end: 2.30),
            SilenceSpan(start: 3.55, end: 4.00),
            SilenceSpan(start: 4.60, end: 5.05),
        ]

        let (_, clauses) = SmartCutDetector.analyzeTranscript(
            tokens: raw,
            duration: 6.0,
            silenceSpans: silences
        )
        #expect(clauses.count == 5)
        #expect(clauses[0].autoReason == .ngRepeat)
        #expect(clauses[1].autoReason == .ngRepeat)
        #expect(clauses[2].autoReason == nil)
        #expect(clauses[3].autoReason == .filler)
        #expect(clauses[4].autoReason == nil)
    }
}
