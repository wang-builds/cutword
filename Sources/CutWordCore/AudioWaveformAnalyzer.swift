import Foundation
import AVFoundation
import CoreMedia

public enum AudioWaveformError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "媒体文件中未检测到音轨。"
        case .readerFailed(let msg):
            return "音频波形读取失败：\(msg)"
        }
    }
}

public struct AudioAcousticProfile: Sendable {
    public let duration: Double
    public let sampleRate: Double
    public let windowSec: Double
    public let windowRmsDb: [Float]
    public let waveformPeaks: [Float]

    public func detectSilences(thresholdDb: Float, minDuration: Double) -> [SilenceSpan] {
        guard !windowRmsDb.isEmpty else { return [] }
        var spans: [SilenceSpan] = []
        var silentStartIdx: Int? = nil

        for (idx, db) in windowRmsDb.enumerated() {
            if db < thresholdDb {
                if silentStartIdx == nil {
                    silentStartIdx = idx
                }
            } else if let sIdx = silentStartIdx {
                let startSec = Double(sIdx) * windowSec
                let endSec = min(duration, Double(idx) * windowSec)
                if endSec - startSec >= minDuration {
                    spans.append(SilenceSpan(start: startSec, end: endSec))
                }
                silentStartIdx = nil
            }
        }

        if let sIdx = silentStartIdx {
            let startSec = Double(sIdx) * windowSec
            let endSec = duration
            if endSec - startSec >= minDuration {
                spans.append(SilenceSpan(start: startSec, end: endSec))
            }
        }

        return spans
    }
}

public enum AudioWaveformAnalyzer {
    public static func analyze(
        url: URL,
        waveformBinCount: Int = 240,
        windowSec: Double = 0.02
    ) async throws -> AudioAcousticProfile {
        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let duration = max(0, durationTime.seconds)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw AudioWaveformError.noAudioTrack
        }

        let targetSampleRate: Double = 16000
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioWaveformError.readerFailed("无法挂载 PCM 解码轨道")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioWaveformError.readerFailed(reader.error?.localizedDescription ?? "未知读取错误")
        }

        let samplesPerWindow = max(1, Int(targetSampleRate * windowSec))
        var windowRmsDb: [Float] = []
        var windowLinearPeaks: [Float] = []

        var sumSquares: Double = 0
        var currentPeak: Float = 0
        var countInWindow: Int = 0

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            if status == kCMBlockBufferNoErr, let basePtr = dataPointer, totalLength >= 4 {
                let floatCount = totalLength / MemoryLayout<Float>.size
                basePtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floatBuf in
                    for i in 0..<floatCount {
                        let s = floatBuf[i]
                        let absVal = abs(s)
                        if absVal > currentPeak { currentPeak = absVal }
                        sumSquares += Double(s * s)
                        countInWindow += 1
                        if countInWindow >= samplesPerWindow {
                            let rms = sqrt(sumSquares / Double(countInWindow))
                            let db = rms > 1e-6 ? Float(20.0 * log10(rms)) : -96.0
                            windowRmsDb.append(db)
                            windowLinearPeaks.append(currentPeak)
                            sumSquares = 0
                            currentPeak = 0
                            countInWindow = 0
                        }
                    }
                }
            }
        }

        if countInWindow > 0 {
            let rms = sqrt(sumSquares / Double(countInWindow))
            let db = rms > 1e-6 ? Float(20.0 * log10(rms)) : -96.0
            windowRmsDb.append(db)
            windowLinearPeaks.append(currentPeak)
        }

        let bins = max(16, waveformBinCount)
        var peaks = Array(repeating: Float(0.04), count: bins)
        if !windowLinearPeaks.isEmpty {
            let maxPeak = max(0.01, windowLinearPeaks.max() ?? 1.0)
            for b in 0..<bins {
                let startIdx = Int((Double(b) / Double(bins)) * Double(windowLinearPeaks.count))
                let endIdx = max(startIdx + 1, Int((Double(b + 1) / Double(bins)) * Double(windowLinearPeaks.count)))
                let clampedEnd = min(windowLinearPeaks.count, endIdx)
                if startIdx < clampedEnd {
                    let sliceMax = windowLinearPeaks[startIdx..<clampedEnd].max() ?? 0
                    peaks[b] = min(1.0, max(0.04, sliceMax / maxPeak))
                }
            }
        }

        let effectiveDuration = duration > 0 ? duration : Double(windowRmsDb.count) * windowSec
        return AudioAcousticProfile(
            duration: effectiveDuration,
            sampleRate: targetSampleRate,
            windowSec: windowSec,
            windowRmsDb: windowRmsDb,
            waveformPeaks: peaks
        )
    }
}
