import Foundation
import AVFoundation
import Speech
import CoreMedia

public enum SpeechEngineError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioTrack
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "当前设备不支持离线语音模型：\(id)"
        case .noAudioTrack:
            return "视频文件中未检测到音轨。"
        case .readerFailed(let msg):
            return "读取音频流失败：\(msg)"
        }
    }
}

public enum SpeechEngine {
    public static func transcribe(
        url: URL,
        localeIdentifier: String = "zh-CN",
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [WordToken] {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw SpeechEngineError.unsupportedLocale(localeIdentifier)
        }

        _ = try? await AssetInventory.reserve(locale: locale)
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                onProgress?("正在首次下载系统离线语音包 (\(locale.identifier))...")
                try await req.downloadAndInstall()
            }
        }

        onProgress?("正在使用 Apple Neural Engine 本地逐字识别...")
        let asset = AVURLAsset(url: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collectTask = Task<[WordToken], Error> {
            var collected: [WordToken] = []
            for try await res in transcriber.results {
                let segStart = max(0, res.range.start.seconds)
                let segEnd = max(segStart, res.range.end.seconds)
                var segTokens: [WordToken] = []

                for run in res.text.runs {
                    let rawSub = String(res.text[run.range].characters)
                    if rawSub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continue
                    }
                    let conf = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] ?? 1.0
                    if let tr = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
                       tr.start.seconds.isFinite,
                       tr.end.seconds.isFinite {
                        segTokens.append(
                            WordToken(
                                text: rawSub,
                                start: max(0, tr.start.seconds),
                                end: max(tr.start.seconds, tr.end.seconds),
                                confidence: conf
                            )
                        )
                    } else {
                        let fallbackStart = segTokens.last?.end ?? segStart
                        segTokens.append(
                            WordToken(
                                text: rawSub,
                                start: fallbackStart,
                                end: max(fallbackStart + 0.04, min(segEnd, fallbackStart + 0.16)),
                                confidence: conf
                            )
                        )
                    }
                }
                collected.append(contentsOf: segTokens)
            }
            return collected
        }

        if #available(macOS 27.0, *) {
            let provider = try await AssetInputSequenceProvider.provider(
                from: asset,
                compatibleWith: [transcriber]
            )
            _ = try await analyzer.analyzeSequence(provider.analyzerInputs)
        } else {
            let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            let stream = try await makeLegacyAudioInputStream(asset: asset, targetFormat: targetFormat)
            _ = try await analyzer.analyzeSequence(stream)
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let rawTokens = try await collectTask.value
        return normalizeTokenOrder(rawTokens)
    }

    private static func makeLegacyAudioInputStream(
        asset: AVURLAsset,
        targetFormat: AVAudioFormat
    ) async throws -> AsyncThrowingStream<AnalyzerInput, Error> {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw SpeechEngineError.noAudioTrack
        }
        let sampleRate = targetFormat.sampleRate
        let channels = Int(targetFormat.channelCount)
        let isFloat = targetFormat.commonFormat == .pcmFormatFloat32

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: isFloat ? 32 : 16,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !targetFormat.isInterleaved,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw SpeechEngineError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var inputs: [AnalyzerInput] = []
        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        while reader.status == .reading, let sbuf = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            var length = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPtr
            )
            guard status == kCMBlockBufferNoErr, let ptr = dataPtr, length >= bytesPerFrame, bytesPerFrame > 0 else {
                continue
            }
            let frames = AVAudioFrameCount(length / bytesPerFrame)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            if let dst = pcm.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, ptr, Int(frames) * bytesPerFrame)
                inputs.append(AnalyzerInput(buffer: pcm, bufferStartTime: pts))
            }
        }
        return AsyncThrowingStream { continuation in
            for item in inputs {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }

    private static func normalizeTokenOrder(_ tokens: [WordToken]) -> [WordToken] {
        guard !tokens.isEmpty else { return [] }
        var sorted = tokens.sorted {
            if abs($0.start - $1.start) > 0.0005 {
                return $0.start < $1.start
            }
            return $0.end < $1.end
        }
        for i in 1..<sorted.count {
            if sorted[i].start < sorted[i - 1].end - 0.02 {
                sorted[i].start = sorted[i - 1].end
                sorted[i].end = max(sorted[i].start + 0.02, sorted[i].end)
            }
        }
        return sorted
    }
}
