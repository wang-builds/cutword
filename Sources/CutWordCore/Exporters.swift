import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import AppKit

public enum ExporterError: LocalizedError {
    case emptyKeepSegments
    case exportSessionCreationFailed
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyKeepSegments:
            return "没有可导出的保留片段，请至少保留一句台词。"
        case .exportSessionCreationFailed:
            return "无法创建硬件视频编码会话。"
        case .exportFailed(let msg):
            return "导出视频失败：\(msg)"
        }
    }
}

public enum SubtitleExporter {
    public static func formatSRT(cues: [CaptionCue]) -> String {
        var lines: [String] = []
        for (idx, cue) in cues.enumerated() {
            lines.append("\(idx + 1)")
            lines.append("\(formatSRTTimestamp(cue.outputStart)) --> \(formatSRTTimestamp(cue.outputEnd))")
            lines.append(cue.plainText)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func formatSRTTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000.0).rounded())
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let sec = totalSec % 60
        let totalMin = totalSec / 60
        let min = totalMin % 60
        let hr = totalMin / 60
        return String(format: "%02d:%02d:%02d,%03d", hr, min, sec, ms)
    }

    public static func formatFCPXML(
        sourceURL: URL,
        projectName: String,
        renderWidth: Int,
        renderHeight: Int,
        fps: Int = 30,
        plan: EditPlan
    ) -> String {
        let safeName = xmlEscape(projectName)
        let srcString = xmlEscape(sourceURL.absoluteString)
        let totalTicks = Int((plan.outputDuration * Double(fps) * 100.0).rounded())
        let srcTicks = Int((plan.originalDuration * Double(fps) * 100.0).rounded())
        let frameDur = "100/\(fps * 100)s"

        var clipXml: [String] = []
        for (idx, seg) in plan.keepSegments.enumerated() {
            let offsetTicks = Int((seg.outputStart * Double(fps) * 100.0).rounded())
            let startTicks = Int((seg.sourceStart * Double(fps) * 100.0).rounded())
            let durTicks = max(100, Int((seg.duration * Double(fps) * 100.0).rounded()))
            clipXml.append(
                "              <asset-clip name=\"Segment \(idx + 1)\" ref=\"r2\" offset=\"\(offsetTicks)/\(fps * 100)s\" start=\"\(startTicks)/\(fps * 100)s\" duration=\"\(durTicks)/\(fps * 100)s\"/>"
            )
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" name="FFVideoFormatRateUndefined" frameDuration="\(frameDur)" width="\(renderWidth)" height="\(renderHeight)"/>
            <asset id="r2" name="\(safeName)" start="0s" duration="\(srcTicks)/\(fps * 100)s" hasVideo="1" hasAudio="1">
              <media-rep kind="original-media" src="\(srcString)"/>
            </asset>
          </resources>
          <library>
            <event name="CutWord Export">
              <project name="\(safeName)">
                <sequence format="r1" duration="\(totalTicks)/\(fps * 100)s" tcStart="0s" tcFormat="NDF">
                  <spine>
        \(clipXml.joined(separator: "\n"))
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Thread-safe Karaoke subtitle bitmap cache & CoreImage overlay renderer.
public final class KaraokeOverlayCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]
    private let cues: [CaptionCue]

    public init(cues: [CaptionCue]) {
        self.cues = cues
    }

    public func composite(over sourceImage: CIImage, at timeSec: Double) -> CIImage {
        guard let cue = findCue(at: timeSec) else {
            return sourceImage
        }

        var activeWordIdx = -1
        for (idx, w) in cue.words.enumerated() {
            if timeSec >= w.outputStart - 0.02 && timeSec <= w.outputEnd + 0.06 {
                activeWordIdx = idx
                break
            } else if timeSec > w.outputEnd {
                activeWordIdx = idx
            }
        }

        let extent = sourceImage.extent
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 64, height > 64 else { return sourceImage }

        let key = "\(cue.index)_\(activeWordIdx)_\(width)x\(height)"
        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing.composited(over: sourceImage)
        }
        lock.unlock()

        guard let overlay = Self.renderOverlay(
            cue: cue,
            activeWordIndex: activeWordIdx,
            canvasWidth: width,
            canvasHeight: height
        ) else {
            return sourceImage
        }

        lock.lock()
        if cache.count > 96 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = overlay
        lock.unlock()

        return overlay.composited(over: sourceImage)
    }

    private func findCue(at t: Double) -> CaptionCue? {
        var lo = 0
        var hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = cues[mid]
            if t < c.outputStart {
                hi = mid - 1
            } else if t > c.outputEnd {
                lo = mid + 1
            } else {
                return c
            }
        }
        return nil
    }

    private static func renderOverlay(
        cue: CaptionCue,
        activeWordIndex: Int,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> CIImage? {
        let isPortrait = canvasHeight > canvasWidth
        let fontSize: CGFloat = isPortrait
            ? max(28, CGFloat(canvasWidth) * 0.056)
            : max(24, CGFloat(canvasHeight) * 0.052)

        let font = NSFont(name: "PingFangSC-Semibold", size: fontSize)
            ?? NSFont.boldSystemFont(ofSize: fontSize)

        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let attrStr = NSMutableAttributedString()
        for (idx, word) in cue.words.enumerated() {
            let isHighlighted = (idx == activeWordIndex)
            let fgColor = isHighlighted
                ? NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.12, alpha: 1.0)
                : NSColor.white
            let part = NSAttributedString(
                string: word.text,
                attributes: [
                    .font: font,
                    .foregroundColor: fgColor,
                    .paragraphStyle: para,
                ]
            )
            attrStr.append(part)
        }

        let maxTextWidth = CGFloat(canvasWidth) * 0.86
        let textBounds = attrStr.boundingRect(
            with: NSSize(width: maxTextWidth, height: CGFloat(canvasHeight) * 0.3),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let padX: CGFloat = fontSize * 0.58
        let padY: CGFloat = fontSize * 0.28
        let pillW = min(CGFloat(canvasWidth) * 0.92, ceil(textBounds.width) + padX * 2)
        let pillH = ceil(textBounds.height) + padY * 2

        let bottomMargin: CGFloat = isPortrait
            ? CGFloat(canvasHeight) * 0.13
            : CGFloat(canvasHeight) * 0.085

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasWidth,
            pixelsHigh: canvasHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: canvasWidth * 4,
            bitsPerPixel: 32
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = nsCtx

        let pillX = (CGFloat(canvasWidth) - pillW) * 0.5
        let pillY = bottomMargin
        let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)

        let path = NSBezierPath(roundedRect: pillRect, xRadius: pillH * 0.32, yRadius: pillH * 0.32)
        NSColor(calibratedWhite: 0.04, alpha: 0.74).setFill()
        path.fill()

        NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // Draw crisp dark text shadow/stroke backdrop first, then foreground fill
        let strokeAttr = NSMutableAttributedString(attributedString: attrStr)
        strokeAttr.addAttributes(
            [
                .strokeColor: NSColor(calibratedWhite: 0.0, alpha: 0.92),
                .strokeWidth: 4.5,
            ],
            range: NSRange(location: 0, length: strokeAttr.length)
        )

        let drawRect = NSRect(
            x: pillX + padX,
            y: pillY + padY - fontSize * 0.05,
            width: pillW - padX * 2,
            height: ceil(textBounds.height) + fontSize * 0.2
        )
        strokeAttr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        attrStr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        NSGraphicsContext.restoreGraphicsState()
        return CIImage(bitmapImageRep: rep)
    }
}

public enum VideoExporter {
    public struct ComposedTimeline: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let videoComposition: AVVideoComposition?
        public let audioMix: AVMutableAudioMix?
        public let renderSize: CGSize
    }

    public static func buildComposition(
        sourceURL: URL,
        plan: EditPlan,
        burnCaptions: Bool
    ) async throws -> ComposedTimeline {
        guard !plan.keepSegments.isEmpty else {
            throw ExporterError.emptyKeepSegments
        }

        let asset = AVURLAsset(url: sourceURL)
        let srcVideoTracks = try await asset.loadTracks(withMediaType: .video)
        let srcAudioTracks = try await asset.loadTracks(withMediaType: .audio)

        let composition = AVMutableComposition()
        let compVideoTrack = srcVideoTracks.isEmpty
            ? nil
            : composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let compAudioTrack = srcAudioTracks.isEmpty
            ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var renderSize = CGSize(width: 1280, height: 720)
        if let vTrack = srcVideoTracks.first {
            let natSize = try await vTrack.load(.naturalSize)
            let prefTransform = try await vTrack.load(.preferredTransform)
            compVideoTrack?.preferredTransform = prefTransform
            let transformed = natSize.applying(prefTransform)
            renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        }

        var cursor = CMTime.zero
        var audioParams: AVMutableAudioMixInputParameters? = nil
        if let compAudio = compAudioTrack {
            audioParams = AVMutableAudioMixInputParameters(track: compAudio)
        }

        for seg in plan.keepSegments {
            let start = CMTime(seconds: seg.sourceStart, preferredTimescale: 600)
            let dur = CMTime(seconds: seg.duration, preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: dur)

            if let srcV = srcVideoTracks.first, let dstV = compVideoTrack {
                try dstV.insertTimeRange(range, of: srcV, at: cursor)
            }
            if let srcA = srcAudioTracks.first, let dstA = compAudioTrack {
                try dstA.insertTimeRange(range, of: srcA, at: cursor)
                // Micro 8ms fade-in/out at cut boundaries to prevent clicks
                if seg.duration > 0.05 {
                    let fadeDur = CMTime(seconds: 0.008, preferredTimescale: 600)
                    audioParams?.setVolumeRamp(fromStartVolume: 0.15, toEndVolume: 1.0, timeRange: CMTimeRange(start: cursor, duration: fadeDur))
                    let outEnd = CMTimeAdd(cursor, dur)
                    let outStart = CMTimeSubtract(outEnd, fadeDur)
                    audioParams?.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.15, timeRange: CMTimeRange(start: outStart, duration: fadeDur))
                }
            }
            cursor = CMTimeAdd(cursor, dur)
        }

        var audioMix: AVMutableAudioMix? = nil
        if let params = audioParams {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        var videoComp: AVVideoComposition? = nil
        if burnCaptions && !srcVideoTracks.isEmpty && !plan.captionCues.isEmpty {
            let renderer = KaraokeOverlayCache(cues: plan.captionCues)
            if #available(macOS 15.0, *) {
                videoComp = try await AVVideoComposition.videoComposition(
                    with: composition,
                    applyingCIFiltersWithHandler: { request in
                        let t = request.compositionTime.seconds
                        let out = renderer.composite(over: request.sourceImage, at: t)
                        request.finish(with: out, context: nil)
                    }
                )
            } else {
                videoComp = makeLegacyVideoComposition(composition: composition, renderer: renderer)
            }
        }

        return ComposedTimeline(
            composition: composition,
            videoComposition: videoComp,
            audioMix: audioMix,
            renderSize: renderSize
        )
    }

    @available(macOS, deprecated: 15.0)
    private static func makeLegacyVideoComposition(
        composition: AVMutableComposition,
        renderer: KaraokeOverlayCache
    ) -> AVVideoComposition {
        AVMutableVideoComposition(asset: composition) { request in
            let t = request.compositionTime.seconds
            let out = renderer.composite(over: request.sourceImage, at: t)
            request.finish(with: out, context: nil)
        }
    }

    public static func exportMP4(
        sourceURL: URL,
        destinationURL: URL,
        plan: EditPlan,
        burnCaptions: Bool
    ) async throws {
        let timeline = try await buildComposition(
            sourceURL: sourceURL,
            plan: plan,
            burnCaptions: burnCaptions
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard let exporter = AVAssetExportSession(
            asset: timeline.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExporterError.exportSessionCreationFailed
        }

        exporter.videoComposition = timeline.videoComposition
        exporter.audioMix = timeline.audioMix
        exporter.shouldOptimizeForNetworkUse = true

        if #available(macOS 15.0, *) {
            try await exporter.export(to: destinationURL, as: .mp4)
        } else {
            try await exportLegacySession(exporter, to: destinationURL)
        }
    }

    @available(macOS, deprecated: 15.0)
    private static func exportLegacySession(_ exporter: AVAssetExportSession, to destinationURL: URL) async throws {
        exporter.outputURL = destinationURL
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
}
