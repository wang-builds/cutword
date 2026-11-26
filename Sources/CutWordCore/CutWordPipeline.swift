import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import AppKit

public enum CutWordPipeline {
    public static func analyzeMedia(
        url: URL,
        localeIdentifier: String = "zh-CN",
        config: CutWordConfig = CutWordConfig(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> MediaAnalysisResult {
        onProgress?("正在扫描 16kHz 音频波形与静音气口...")
        let acoustic = try await AudioWaveformAnalyzer.analyze(url: url)
        let silences = acoustic.detectSilences(
            thresholdDb: config.silenceThresholdDb,
            minDuration: 0.20
        )

        let rawTokens = try await SpeechEngine.transcribe(
            url: url,
            localeIdentifier: localeIdentifier,
            onProgress: onProgress
        )

        onProgress?("正在智能标记口癖词与 NG 重录废句...")
        let (annotatedTokens, clauses) = SmartCutDetector.analyzeTranscript(
            tokens: rawTokens,
            duration: acoustic.duration,
            silenceSpans: silences
        )

        return MediaAnalysisResult(
            sourcePath: url.path,
            duration: acoustic.duration,
            waveformPeaks: acoustic.waveformPeaks,
            silenceSpans: silences,
            tokens: annotatedTokens,
            clauses: clauses
        )
    }
}

public enum SampleVideoBuilder {
    private struct DemoClipSpec {
        let spokenText: String?
        let pauseSeconds: Double
        let stageTitle: String
        let stageSubtitle: String
        let accentRed: Bool
    }

    public static func generateBuiltInDemoVideo(to outputURL: URL) async throws -> URL {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutword-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let specs: [DemoClipSpec] = [
            DemoClipSpec(
                spokenText: nil,
                pauseSeconds: 0.85,
                stageTitle: "开机准备（冷场静音 0.85s）",
                stageSubtitle: "传统剪辑需手动放大时间轴找气口裁剪",
                accentRed: true
            ),
            DemoClipSpec(
                spokenText: "大家好。",
                pauseSeconds: 0,
                stageTitle: "开场问候（自动保留）",
                stageSubtitle: "自然保留首句问候",
                accentRed: false
            ),
            DemoClipSpec(
                spokenText: nil,
                pauseSeconds: 0.65,
                stageTitle: "句间换气（0.65s）",
                stageSubtitle: "切除多余静音，保留 120ms 自然气口",
                accentRed: true
            ),
            DemoClipSpec(
                spokenText: "今天给大家实测一款本地剪辑，不对重来。",
                pauseSeconds: 0,
                stageTitle: "Take 1 · 口播说错半句 + 重录口令（NG 废稿）",
                stageSubtitle: "「今天给大家实测一款本地剪辑，不对重来」—— 自动整句剔除",
                accentRed: true
            ),
            DemoClipSpec(
                spokenText: nil,
                pauseSeconds: 0.85,
                stageTitle: "深呼吸准备重说（冷场静音 0.85s）",
                stageSubtitle: "自动切除静音停顿",
                accentRed: true
            ),
            DemoClipSpec(
                spokenText: "今天给大家实测一款完全免费的本地口播文字剪辑工具。",
                pauseSeconds: 0,
                stageTitle: "Take 2 · 正式顺畅口播（自动保留）",
                stageSubtitle: "智能保留最后一遍完整表达",
                accentRed: false
            ),
            DemoClipSpec(
                spokenText: nil,
                pauseSeconds: 0.75,
                stageTitle: "句间长停顿（冷场静音 0.75s）",
                stageSubtitle: "大于 0.45s 的拖沓气口将被自动剪除",
                accentRed: true
            ),
            DemoClipSpec(
                spokenText: "那个，就是说。",
                pauseSeconds: 0,
                stageTitle: "口癖犹豫词（自动标橙剔除）",
                stageSubtitle: "独立口癖「嗯 / 啊 / 那个 / 就是说」一键净除",
                accentRed: true
            ),
            DemoClipSpec(
                spokenText: nil,
                pauseSeconds: 0.60,
                stageTitle: "口癖后停顿（0.60s）",
                stageSubtitle: "自动收紧节奏",
                accentRed: true
            ),
            DemoClipSpec(
                spokenText: "不用装复杂的环境，也不用开会员，删文字就能直接剪视频并导出字幕！",
                pauseSeconds: 0,
                stageTitle: "核心卖点总结（自动保留）",
                stageSubtitle: "支持直出动态高亮字幕 MP4、剪映免会员 SRT 与达芬奇 FCPXML",
                accentRed: false
            ),
        ]

        // 1. Synthesize spoken AIFF segments via /usr/bin/say (Tingting -> Meijia fallback)
        let composition = AVMutableComposition()
        guard let compAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExporterError.exportFailed("无法创建样片音轨")
        }

        // Create a short silent reference audio file for inserting exact silence gaps
        let silentWavURL = tempDir.appendingPathComponent("silence_unit.wav")
        try writeSilentWav(to: silentWavURL, durationSec: 2.0, sampleRate: 22050)
        let silentAsset = AVURLAsset(url: silentWavURL)
        let silentTrack = try await silentAsset.loadTracks(withMediaType: .audio).first!

        var timelineCards: [(start: Double, end: Double, spec: DemoClipSpec)] = []
        var cursorSec: Double = 0

        for (idx, spec) in specs.enumerated() {
            if let text = spec.spokenText {
                let aiffURL = tempDir.appendingPathComponent("tts_\(idx).aiff")
                try synthesizeMacTTS(text: text, outputURL: aiffURL)
                let ttsAsset = AVURLAsset(url: aiffURL)
                let dur = try await ttsAsset.load(.duration)
                if let aTrack = try await ttsAsset.loadTracks(withMediaType: .audio).first, dur.seconds > 0.05 {
                    let insertAt = CMTime(seconds: cursorSec, preferredTimescale: 600)
                    try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aTrack, at: insertAt)
                    timelineCards.append((cursorSec, cursorSec + dur.seconds, spec))
                    cursorSec += dur.seconds
                }
            } else if spec.pauseSeconds > 0 {
                let insertAt = CMTime(seconds: cursorSec, preferredTimescale: 600)
                let dur = CMTime(seconds: spec.pauseSeconds, preferredTimescale: 600)
                try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: silentTrack, at: insertAt)
                timelineCards.append((cursorSec, cursorSec + spec.pauseSeconds, spec))
                cursorSec += spec.pauseSeconds
            }
        }

        // 2. Render crisp 1280x720 30fps video track into temp video file via AVAssetWriter
        let videoOnlyURL = tempDir.appendingPathComponent("video_only.mp4")
        let fps = 30
        let totalFrames = max(30, Int((cursorSec * Double(fps)).rounded()))
        try await writeDemoVideoFrames(
            to: videoOnlyURL,
            width: 1280,
            height: 720,
            fps: fps,
            totalFrames: totalFrames,
            totalDuration: cursorSec,
            cards: timelineCards
        )

        let vAsset = AVURLAsset(url: videoOnlyURL)
        if let vTrack = try await vAsset.loadTracks(withMediaType: .video).first,
           let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let vDur = try await vAsset.load(.duration)
            let clampDur = CMTimeMinimum(vDur, CMTime(seconds: cursorSec, preferredTimescale: 600))
            try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: clampDur), of: vTrack, at: .zero)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExporterError.exportSessionCreationFailed
        }
        exporter.shouldOptimizeForNetworkUse = true
        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .mp4)
        } else {
            try await exportLegacyDemoSession(exporter, to: outputURL)
        }
        return outputURL
    }

    @available(macOS, deprecated: 15.0)
    private static func exportLegacyDemoSession(_ exporter: AVAssetExportSession, to outputURL: URL) async throws {
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        final class Box: @unchecked Sendable {
            let session: AVAssetExportSession
            init(_ s: AVAssetExportSession) { self.session = s }
        }
        let box = Box(exporter)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                if let err = box.session.error {
                    cont.resume(throwing: err)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    private static func synthesizeMacTTS(text: String, outputURL: URL) throws {
        for voice in ["Tingting", "Meijia", "Sinji"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            proc.arguments = ["-v", voice, "-r", "195", "-o", outputURL.path, text]
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
               let size = attrs[.size] as? UInt64,
               size > 4096 {
                return
            }
        }
        throw ExporterError.exportFailed("系统未找到可用的中文语音合成器 (Tingting/Meijia)")
    }

    private static func writeSilentWav(to url: URL, durationSec: Double, sampleRate: Int) throws {
        let numSamples = Int(durationSec * Double(sampleRate))
        let dataSize = UInt32(numSamples * 2)
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        var chunkSize = UInt32(36 + dataSize).littleEndian
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append("WAVEfmt ".data(using: .ascii)!)
        var subchunk1Size = UInt32(16).littleEndian
        var audioFormat = UInt16(1).littleEndian
        var numChannels = UInt16(1).littleEndian
        var sr = UInt32(sampleRate).littleEndian
        var byteRate = UInt32(sampleRate * 2).littleEndian
        var blockAlign = UInt16(2).littleEndian
        var bitsPerSample = UInt16(16).littleEndian
        header.append(Data(bytes: &subchunk1Size, count: 4))
        header.append(Data(bytes: &audioFormat, count: 2))
        header.append(Data(bytes: &numChannels, count: 2))
        header.append(Data(bytes: &sr, count: 4))
        header.append(Data(bytes: &byteRate, count: 4))
        header.append(Data(bytes: &blockAlign, count: 2))
        header.append(Data(bytes: &bitsPerSample, count: 2))
        header.append("data".data(using: .ascii)!)
        var dSize = dataSize.littleEndian
        header.append(Data(bytes: &dSize, count: 4))
        header.append(Data(count: Int(dataSize)))
        try header.write(to: url)
    }

    private static func writeDemoVideoFrames(
        to url: URL,
        width: Int,
        height: Int,
        fps: Int,
        totalFrames: Int,
        totalDuration: Double,
        cards: [(start: Double, end: Double, spec: DemoClipSpec)]
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Cache one rendered pixel buffer per card index + 0.1s timecode tick for blazing fast generation
        var lastCardIdx = -1
        var cachedCardRep: NSBitmapImageRep? = nil

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let t = Double(frame) / Double(fps)
            let cIdx = cards.firstIndex(where: { t >= $0.start && t < $0.end }) ?? max(0, cards.count - 1)
            if cIdx != lastCardIdx || cachedCardRep == nil {
                lastCardIdx = cIdx
                cachedCardRep = renderStudioCard(
                    width: width,
                    height: height,
                    spec: cards[cIdx].spec,
                    progress: t / max(0.1, totalDuration)
                )
            }

            guard let pool = adaptor.pixelBufferPool else { continue }
            var pbOut: CVPixelBuffer? = nil
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut, let rep = cachedCardRep else { continue }

            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                ), let cgImg = rep.cgImage {
                    ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            adaptor.append(pb, withPresentationTime: pts)
        }

        input.markAsFinished()
        await writer.finishWriting()
    }

    private static func renderStudioCard(
        width: Int,
        height: Int,
        spec: DemoClipSpec,
        progress: Double
    ) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = nsCtx

        // Deep studio slate background
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1.0).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))

        // Studio frame card
        let cardRect = NSRect(x: 90, y: 210, width: width - 180, height: 380)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 28, yRadius: 28)
        NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.21, alpha: 1.0).setFill()
        cardPath.fill()

        let borderColor = spec.accentRed
            ? NSColor(calibratedRed: 0.94, green: 0.30, blue: 0.34, alpha: 0.9)
            : NSColor(calibratedRed: 0.16, green: 0.80, blue: 0.56, alpha: 0.9)
        borderColor.setStroke()
        cardPath.lineWidth = 3.0
        cardPath.stroke()

        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let badgeText = spec.accentRed ? "● 待自动剪除片段 (气口 / 口癖 / NG 重录)" : "● 有效口播干货片段 (自动保留)"
        let badgeAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: borderColor,
            .paragraphStyle: para,
        ]
        (badgeText as NSString).draw(in: NSRect(x: 120, y: 505, width: width - 240, height: 34), withAttributes: badgeAttr)

        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 38),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        (spec.stageTitle as NSString).draw(in: NSRect(x: 120, y: 390, width: width - 240, height: 64), withAttributes: titleAttr)

        let subAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 23, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.65, green: 0.72, blue: 0.84, alpha: 1.0),
            .paragraphStyle: para,
        ]
        (spec.stageSubtitle as NSString).draw(in: NSRect(x: 130, y: 315, width: width - 260, height: 50), withAttributes: subAttr)

        // Progress bar inside card
        let barBg = NSRect(x: 180, y: 256, width: width - 360, height: 10)
        NSColor(calibratedWhite: 1.0, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: barBg, xRadius: 5, yRadius: 5).fill()

        let barFg = NSRect(x: 180, y: 256, width: max(12, CGFloat(width - 360) * CGFloat(progress)), height: 10)
        borderColor.setFill()
        NSBezierPath(roundedRect: barFg, xRadius: 5, yRadius: 5).fill()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
