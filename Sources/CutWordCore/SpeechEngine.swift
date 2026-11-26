import Foundation
import AVFoundation
import Speech
import CoreMedia

public enum SpeechEngineError: LocalizedError {
    case unsupportedLocale(String)
    case offlineModelNotInstalled(String)
    case noAudioTrack
    case readerFailed(String)
    case permissionDenied
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "当前设备暂未启用该语言语音识别（\(id)）。请前往「系统设置 → 键盘 → 听写」（或「通用 → 语言与地区」），开启听写并勾选对应语言触发离线语音包下载。"
        case .offlineModelNotInstalled(let id):
            return "首次使用需下载 macOS 系统离线语音包（\(id)）：请打开「系统设置 → 键盘 → 听写」开启听写并勾选对应语言（联网等待约 1 分钟自动下载完成后，即可永久断网离线识别）。"
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
    public static func friendlyRecognitionError(_ error: Error, localeIdentifier: String) -> SpeechEngineError {
        if let se = error as? SpeechEngineError {
            return se
        }
        let nsErr = error as NSError
        let combined = "\(nsErr.domain) \(nsErr.code) \(nsErr.localizedDescription)".lowercased()
        let missingSignals = [
            "on-device", "on device", "offline", "dictation", "siri", "asset",
            "not available", "not installed", "model", "download", "klsrerrordomain"
        ]
        if missingSignals.contains(where: { combined.contains($0) }) || [201, 203, 1101, 1107].contains(nsErr.code) {
            return .offlineModelNotInstalled(localeIdentifier)
        }
        return .recognitionFailed(error.localizedDescription)
    }

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
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    onProgress?("首次运行正在准备 macOS 系统离线语音包 (\(locale.identifier))，请保持联网片刻...")
                    try await req.downloadAndInstall()
                }
            } catch {
                throw SpeechEngineError.offlineModelNotInstalled(locale.identifier)
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

    /// Fallback for macOS 14 (Sonoma) & macOS 15 (Sequoia) using on-device SFSpeechRecognizer
    /// with punctuation- and word-length-weighted character/word timestamp allocation.
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
                ?? SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier.replacingOccurrences(of: "-", with: "_"))) else {
            throw SpeechEngineError.unsupportedLocale(localeIdentifier)
        }

        guard recognizer.isAvailable else {
            throw SpeechEngineError.offlineModelNotInstalled(localeIdentifier)
        }

        if !recognizer.supportsOnDeviceRecognition {
            onProgress?("提示：尚未检测到「\(localeIdentifier)」系统离线语音包，若离线识别受阻请前往「系统设置 → 键盘 → 听写」开启一次以触发系统下载...")
        } else {
            onProgress?("正在使用 macOS 本地离线语音引擎识别...")
        }

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
                        continuation.resume(throwing: Self.friendlyRecognitionError(error, localeIdentifier: localeIdentifier))
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
        for seg in segments {
            let weighted = allocateWeightedTokens(
                substring: seg.substring,
                start: seg.start,
                duration: seg.duration,
                confidence: seg.confidence
            )
            rawTokens.append(contentsOf: weighted)
        }
        return normalizeTokenOrder(rawTokens)
    }

    /// Allocates sub-segment timestamps weighted by CJK syllable prosody, contiguous English/number word length,
    /// and capped punctuation tails instead of naive uniform character division.
    public static func allocateWeightedTokens(
        substring: String,
        start: Double,
        duration: Double,
        confidence: Double
    ) -> [WordToken] {
        let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let safeDuration = max(0.03, duration)

        let units = splitIntoProsodicUnits(trimmed)
        guard units.count > 1 else {
            return [
                WordToken(
                    text: trimmed,
                    start: start,
                    end: start + safeDuration,
                    confidence: confidence
                )
            ]
        }

        let majorPunct = CharacterSet(charactersIn: "。！？!?…；;")
        let minorPunct = CharacterSet(charactersIn: "，、：:,.")
        let bracketPunct = CharacterSet(charactersIn: "“”‘’\"'「」『』（）()[]【】")

        enum UnitKind {
            case spoken
            case majorPunctuation
            case minorPunctuation
        }

        var kinds: [UnitKind] = []
        var weights: [Double] = []
        var lastSpokenIdx: Int?

        for (idx, unit) in units.enumerated() {
            let scalars = unit.unicodeScalars
            if scalars.allSatisfy({ majorPunct.contains($0) }) {
                kinds.append(.majorPunctuation)
                weights.append(0.20)
            } else if scalars.allSatisfy({ minorPunct.contains($0) || bracketPunct.contains($0) || CharacterSet.punctuationCharacters.contains($0) }) {
                kinds.append(.minorPunctuation)
                weights.append(scalars.allSatisfy({ bracketPunct.contains($0) }) ? 0.08 : 0.14)
            } else {
                kinds.append(.spoken)
                lastSpokenIdx = idx
                let isASCIIWord = scalars.allSatisfy { $0.isASCII }
                if isASCIIWord {
                    // Scale English/number token duration smoothly with character length
                    let w = max(0.65, min(2.60, 0.50 + Double(unit.count) * 0.28))
                    weights.append(w)
                } else {
                    weights.append(1.0)
                }
            }
        }

        // Apply natural Mandarin phrase-final syllable lengthening (+15%) on the last spoken token
        if let lastSpokenIdx {
            weights[lastSpokenIdx] *= 1.15
        }

        let totalWeight = max(0.001, weights.reduce(0, +))
        var durations = weights.map { safeDuration * ($0 / totalWeight) }

        // Cap punctuation token durations so trailing commas/periods never steal speech time from words
        let spokenIndices = kinds.indices.filter { kinds[$0] == .spoken }
        if !spokenIndices.isEmpty {
            var reclaimed: Double = 0
            for i in kinds.indices where kinds[i] != .spoken {
                let cap = kinds[i] == .majorPunctuation
                    ? min(0.08, safeDuration * 0.18)
                    : min(0.05, safeDuration * 0.12)
                if durations[i] > cap {
                    reclaimed += durations[i] - cap
                    durations[i] = cap
                }
            }
            if reclaimed > 0 {
                let spokenWeightSum = max(0.001, spokenIndices.reduce(0.0) { $0 + weights[$1] })
                for idx in spokenIndices {
                    durations[idx] += reclaimed * (weights[idx] / spokenWeightSum)
                }
            }
        }

        var out: [WordToken] = []
        var cursor = start
        for i in units.indices {
            let tokenEnd = (i == units.count - 1) ? (start + safeDuration) : (cursor + durations[i])
            out.append(
                WordToken(
                    text: units[i],
                    start: cursor,
                    end: max(cursor + 0.01, tokenEnd),
                    confidence: confidence
                )
            )
            cursor = tokenEnd
        }
        return out
    }

    private static func splitIntoProsodicUnits(_ text: String) -> [String] {
        let cjkSet = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
            .union(CharacterSet(charactersIn: "\u{3040}"..."\u{30FF}"))
            .union(CharacterSet(charactersIn: "\u{AC00}"..."\u{D7AF}"))
        let hasCJK = text.unicodeScalars.contains { cjkSet.contains($0) }
        guard hasCJK else {
            // Pure English/Latin segment from SFSpeechRecognizer is already a single word (+ optional trailing punct)
            return [text]
        }

        var units: [String] = []
        var asciiBuffer = ""

        let flushASCII = {
            if !asciiBuffer.isEmpty {
                units.append(asciiBuffer)
                asciiBuffer.removeAll(keepingCapacity: true)
            }
        }

        for ch in text {
            if ch.isWhitespace {
                flushASCII()
                continue
            }
            let scalars = String(ch).unicodeScalars
            let isASCIIWordChar = scalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "-" || $0 == ".")
            }
            if isASCIIWordChar {
                asciiBuffer.append(ch)
            } else {
                flushASCII()
                units.append(String(ch))
            }
        }
        flushASCII()
        return units
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
