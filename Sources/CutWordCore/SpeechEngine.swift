import Foundation
import AVFoundation
import Speech
import CoreMedia

public enum SpeechEngineError: LocalizedError {
    case unsupportedLocale(String)
    case noAudioTrack
    case readerFailed(String)
    case permissionDenied
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "当前设备不支持离线语音模型：\(id)"
        case .noAudioTrack:
            return "视频文件中未检测到音轨。"
        case .readerFailed(let msg):
            return "读取音频流失败：\(msg)"
        case .permissionDenied:
            return "请在「系统设置 → 隐私与安全性 → 语音识别」中允许 CutWord 使用本地语音识别。"
        case .recognitionFailed(let msg):
            return "本地语音识别失败：\(msg)"
        }
    }
}

public enum SpeechEngine {
    public static func transcribe(
        url: URL,
        localeIdentifier: String = "zh-CN",
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [WordToken] {
        if #available(macOS 26.0, *) {
            return try await transcribeWithModernAnalyzer(
                url: url,
                localeIdentifier: localeIdentifier,
                onProgress: onProgress
            )
        } else {
            return try await transcribeWithLegacySFSpeech(
                url: url,
                localeIdentifier: localeIdentifier,
                onProgress: onProgress
            )
        }
    }

    @available(macOS 26.0, *)
    private static func transcribeWithModernAnalyzer(
        url: URL,
        localeIdentifier: String,
        onProgress: (@Sendable (String) -> Void)?
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

    /// Fallback for macOS 14 (Sonoma) & macOS 15 (Sequoia) using on-device SFSpeechRecognizer.
    private static func transcribeWithLegacySFSpeech(
        url: URL,
        localeIdentifier: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> [WordToken] {
        let authStatus = await requestSFSpeechAuthorizationIfNeeded()
        if authStatus == .denied || authStatus == .restricted {
            throw SpeechEngineError.permissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
                ?? SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier.replacingOccurrences(of: "-", with: "_"))),
              recognizer.isAvailable else {
            throw SpeechEngineError.unsupportedLocale(localeIdentifier)
        }

        onProgress?("正在使用 macOS 本地离线语音引擎识别...")
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let segments: [(substring: String, start: Double, duration: Double, confidence: Double)] = try await withCheckedThrowingContinuation { continuation in
            final class ResumeGate: @unchecked Sendable {
                let lock = NSLock()
                var done = false
                func claim() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if done { return false }
                    done = true
                    return true
                }
            }
            let gate = ResumeGate()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if gate.claim() {
                        continuation.resume(throwing: SpeechEngineError.recognitionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                let extracted = result.bestTranscription.segments.map { seg in
                    (
                        substring: seg.substring,
                        start: max(0, seg.timestamp),
                        duration: max(0.04, seg.duration),
                        confidence: seg.confidence > 0 ? Double(seg.confidence) : 1.0
                    )
                }
                if gate.claim() {
                    continuation.resume(returning: extracted)
                }
            }
        }

        var rawTokens: [WordToken] = []
        let cjkRange = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
        for seg in segments {
            let trimmed = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let chars = Array(trimmed)
            let hasCJK = trimmed.unicodeScalars.contains { cjkRange.contains($0) }
            if hasCJK && chars.count > 1 {
                let step = seg.duration / Double(chars.count)
                for (idx, ch) in chars.enumerated() {
                    let s = seg.start + Double(idx) * step
                    rawTokens.append(
                        WordToken(
                            text: String(ch),
                            start: s,
                            end: s + max(0.03, step),
                            confidence: seg.confidence
                        )
                    )
                }
            } else {
                rawTokens.append(
                    WordToken(
                        text: trimmed,
                        start: seg.start,
                        end: seg.start + seg.duration,
                        confidence: seg.confidence
                    )
                )
            }
        }
        return normalizeTokenOrder(rawTokens)
    }

    private static func requestSFSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    @available(macOS 26.0, *)
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
