import Foundation

public enum SmartCutDetector {
    private static let singleFillers: Set<String> = [
        "嗯", "啊", "呃", "额", "噢", "哦", "唉", "诶", "唔",
        "um", "uh", "er", "ah", "hmm", "uhh", "umm"
    ]

    private static let multiCharFillers: [String] = [
        "那个", "就是说", "怎么说呢", "呃那个", "嗯那个"
    ]

    private static let retakeInterjections: [String] = [
        "不对重来", "说错了重来", "重来一遍", "重说一遍", "哎不对", "等下重来", "卡壳了", "算了重来"
    ]

    private static let homophoneBuckets: [String] = [
        "的得地", "在再载", "做作坐座", "他她它", "题提啼", "视事市式试是世",
        "频平评屏瓶", "竞净静境镜劲", "剪简检减捡", "字自子紫", "幕目木牧",
        "器气汽弃契", "员元园源原圆", "费废沸", "零灵铃凌", "工功公攻", "具剧据句"
    ]

    private static let phoneticMap: [Character: Character] = {
        var map: [Character: Character] = [:]
        for group in homophoneBuckets {
            guard let canon = group.first else { continue }
            for ch in group {
                map[ch] = canon
            }
        }
        return map
    }()

    public static func analyzeTranscript(
        tokens: [WordToken],
        duration: Double,
        silenceSpans: [SilenceSpan]
    ) -> (tokens: [WordToken], clauses: [TranscriptClause]) {
        guard !tokens.isEmpty else { return ([], []) }
        var annotated = tokens

        // 0. Snap ASR tokens whose leading start (or trailing end) was stretched across a true 16kHz acoustic silence.
        // Apple SpeechTranscriber commonly sets nextToken.start = prevToken.end across a pause, gluing silence to the front.
        for i in 0..<annotated.count {
            let tStart = annotated[i].start
            let tEnd = annotated[i].end
            guard tEnd - tStart > 0.26 else { continue }
            if annotated[i].isPunctuationOnly {
                annotated[i].end = min(tEnd, tStart + 0.08)
                continue
            }
            for sil in silenceSpans where sil.duration >= 0.26 {
                let beforeSil = sil.start - tStart
                let afterSil = tEnd - sil.end
                if beforeSil <= 0.22 && afterSil >= 0.04 && sil.end > tStart {
                    annotated[i].start = min(tEnd - 0.04, sil.end - 0.02)
                    break
                } else if beforeSil >= 0.12 && afterSil <= 0.06 && sil.start < tEnd {
                    annotated[i].end = max(tStart + 0.04, sil.start + 0.02)
                    break
                }
            }
        }

        // 1. Group tokens into natural spoken clauses (using punctuation, acoustic silences, and retake cues)
        var clauses: [TranscriptClause] = []
        var currentIndices: [Int] = []
        let sentenceBreakChars = CharacterSet(charactersIn: "。！？；，,.!?;…")

        for i in 0..<annotated.count {
            let tok = annotated[i]
            if !currentIndices.isEmpty, let prevIdx = currentIndices.last {
                let prevTok = annotated[prevIdx]
                let gap = tok.start - prevTok.end
                let hasAcousticBreak = silenceSpans.contains { sil in
                    sil.duration >= 0.32 &&
                    sil.start >= prevTok.start + 0.05 &&
                    sil.end <= tok.start + 0.12
                }
                if gap >= 0.34 || hasAcousticBreak {
                    clauses.append(makeClause(indices: currentIndices, tokens: annotated))
                    currentIndices.removeAll(keepingCapacity: true)
                }
            }
            currentIndices.append(i)
            let scalars = tok.text.unicodeScalars
            let runningPlain = currentIndices
                .map { annotated[$0].text }
                .joined()
                .unicodeScalars
                .filter { !sentenceBreakChars.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
                .map(String.init)
                .joined()

            let hitRetakeEnd = retakeInterjections.contains { runningPlain.hasSuffix($0) }
            if scalars.contains(where: { sentenceBreakChars.contains($0) }) || hitRetakeEnd {
                clauses.append(makeClause(indices: currentIndices, tokens: annotated))
                currentIndices.removeAll(keepingCapacity: true)
            }
        }
        if !currentIndices.isEmpty {
            clauses.append(makeClause(indices: currentIndices, tokens: annotated))
        }

        // 2. Detect standalone/compound filler clauses, explicit retake clauses & isolated hesitation tokens
        for cIdx in 0..<clauses.count {
            let plain = normalizedPlainText(clause: clauses[cIdx], tokens: annotated)
            if plain.isEmpty { continue }

            if retakeInterjections.contains(where: { plain.hasSuffix($0) || (plain.contains($0) && plain.count <= 12) }) {
                clauses[cIdx].autoReason = .ngRepeat
                for tIdx in clauses[cIdx].tokenIndices {
                    annotated[tIdx].autoCutReason = .ngRepeat
                }
                continue
            }

            if isPureFillerPhrase(plain) {
                clauses[cIdx].autoReason = .filler
                for tIdx in clauses[cIdx].tokenIndices {
                    annotated[tIdx].autoCutReason = .filler
                }
                continue
            }

            // Leading compound hesitation ("那个就是说" / "就是说" / "怎么说呢") or single-char hesitation
            let spokenIndices = clauses[cIdx].tokenIndices.filter { !annotated[$0].isPunctuationOnly }
            for prefix in ["那个就是说", "嗯那个", "呃那个", "就是说", "怎么说呢"] {
                if plain.hasPrefix(prefix) && plain.count > prefix.count + 2 {
                    var consumed = 0
                    for idx in spokenIndices {
                        let t = annotated[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                        annotated[idx].autoCutReason = .filler
                        consumed += t.count
                        if consumed >= prefix.count { break }
                    }
                    break
                }
            }
            if let firstSpoken = spokenIndices.first, annotated[firstSpoken].autoCutReason == nil {
                let firstText = annotated[firstSpoken].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if singleFillers.contains(firstText) {
                    let nextGap: Double
                    if spokenIndices.count >= 2 {
                        nextGap = annotated[spokenIndices[1]].start - annotated[firstSpoken].end
                    } else {
                        nextGap = 0.5
                    }
                    if nextGap >= 0.14 || spokenIndices.count == 1 {
                        annotated[firstSpoken].autoCutReason = .filler
                    }
                }
            }
        }

        // 3. Detect NG repeated bad takes across adjacent clauses (including across a short retake interjection)
        for i in 0..<clauses.count {
            if clauses[i].autoReason != nil { continue }
            let normA = phoneticNormalized(clause: clauses[i], tokens: annotated)
            if normA.count < 4 { continue }

            // Look ahead up to 2 clauses within 5.5 seconds
            let maxLookahead = min(clauses.count - 1, i + 2)
            if i + 1 <= maxLookahead {
                for j in (i + 1)...maxLookahead {
                    if clauses[j].autoReason == .filler || clauses[j].autoReason == .ngRepeat {
                        continue
                    }
                    let gap = clauses[j].start - clauses[i].end
                    if gap > 5.5 { break }
                    let normB = phoneticNormalized(clause: clauses[j], tokens: annotated)
                    if normB.count < 4 { continue }

                    if isLikelyNGRetake(earlier: normA, later: normB) {
                        clauses[i].autoReason = .ngRepeat
                        for tIdx in clauses[i].tokenIndices {
                            annotated[tIdx].autoCutReason = .ngRepeat
                        }
                        // Also mark any short bridge clause between i and j as ngRepeat
                        if j == i + 2 {
                            clauses[i + 1].autoReason = .ngRepeat
                            for tIdx in clauses[i + 1].tokenIndices {
                                annotated[tIdx].autoCutReason = .ngRepeat
                            }
                        }
                        break
                    }
                }
            }
        }

        return (annotated, clauses)
    }

    public static func compileEditPlan(
        tokens: [WordToken],
        clauses: [TranscriptClause],
        silenceSpans: [SilenceSpan],
        duration: Double,
        config: CutWordConfig
    ) -> EditPlan {
        guard duration > 0 else {
            return EditPlan(
                originalDuration: 0,
                outputDuration: 0,
                keepSegments: [],
                captionCues: [],
                cutSilenceCount: 0,
                cutFillerCount: 0,
                cutNGClauseCount: 0
            )
        }

        var cutFillerCount = 0
        for tok in tokens where !tok.isPunctuationOnly {
            if tok.effectiveCutReason(
                removeFillers: config.removeFillers,
                removeNGRepeats: config.removeNGRepeats
            ) == .filler {
                cutFillerCount += 1
            }
        }

        let cutNGClauseCount = clauses.filter { clause in
            let activeReasons = clause.tokenIndices.compactMap {
                tokens[$0].effectiveCutReason(
                    removeFillers: config.removeFillers,
                    removeNGRepeats: config.removeNGRepeats
                )
            }
            return !activeReasons.isEmpty && activeReasons.contains(.ngRepeat)
        }.count

        // Collect kept spoken tokens
        let keptTokenIndices = tokens.indices.filter { idx in
            let tok = tokens[idx]
            if tok.isPunctuationOnly { return false }
            return tok.effectiveCutReason(
                removeFillers: config.removeFillers,
                removeNGRepeats: config.removeNGRepeats
            ) == nil
        }

        // Fallback if no speech tokens exist: cut pure acoustic silences only
        if keptTokenIndices.isEmpty {
            if !config.removeSilences || silenceSpans.isEmpty {
                let full = KeepSegment(
                    sourceStart: 0,
                    sourceEnd: duration,
                    outputStart: 0,
                    outputEnd: duration
                )
                return EditPlan(
                    originalDuration: duration,
                    outputDuration: duration,
                    keepSegments: [full],
                    captionCues: [],
                    cutSilenceCount: 0,
                    cutFillerCount: 0,
                    cutNGClauseCount: 0
                )
            }
            let rawKeep = invertSilences(
                silences: silenceSpans.filter { $0.duration >= config.minSilenceDuration },
                duration: duration,
                pad: config.breathPaddingSec
            )
            let segs = buildKeepSegments(from: rawKeep)
            return EditPlan(
                originalDuration: duration,
                outputDuration: segs.last?.outputEnd ?? 0,
                keepSegments: segs,
                captionCues: [],
                cutSilenceCount: max(0, segs.count - 1),
                cutFillerCount: 0,
                cutNGClauseCount: 0
            )
        }

        // Build padded intervals around every kept token
        let pad = max(0.02, config.breathPaddingSec)
        let mergeGapThreshold = config.removeSilences ? max(0.18, config.minSilenceDuration) : 10_000.0

        var rawIntervals: [(Double, Double)] = []
        for idx in keptTokenIndices {
            let t = tokens[idx]
            let s = max(0, t.start - pad)
            let e = min(duration, max(t.end + pad, s + 0.06))
            rawIntervals.append((s, e))
        }

        // Note: Do NOT merge across explicitly cut tokens (manual / filler / NG)!
        let cutTokenRanges: [(Double, Double)] = tokens.compactMap { tok in
            guard !tok.isPunctuationOnly else { return nil }
            guard tok.effectiveCutReason(
                removeFillers: config.removeFillers,
                removeNGRepeats: config.removeNGRepeats
            ) != nil else { return nil }
            return (tok.start, tok.end)
        }

        var mergedIntervals: [(Double, Double)] = []
        for interval in rawIntervals {
            if let last = mergedIntervals.last {
                let gap = interval.0 - last.1
                let hasCutTokenBetween = cutTokenRanges.contains { cut in
                    cut.1 > last.1 - pad * 0.8 && cut.0 < interval.0 + pad * 0.8
                }
                if !hasCutTokenBetween && gap < mergeGapThreshold {
                    mergedIntervals[mergedIntervals.count - 1] = (last.0, max(last.1, interval.1))
                } else {
                    mergedIntervals.append(interval)
                }
            } else {
                mergedIntervals.append(interval)
            }
        }

        // Prevent tiny overlap if padding touched a cut token
        for i in 1..<mergedIntervals.count {
            if mergedIntervals[i].0 < mergedIntervals[i - 1].1 {
                let mid = (mergedIntervals[i - 1].1 + mergedIntervals[i].0) * 0.5
                mergedIntervals[i - 1].1 = mid
                mergedIntervals[i].0 = mid
            }
        }

        let keepSegments = buildKeepSegments(from: mergedIntervals)
        let cutSilenceCount = config.removeSilences
            ? silenceSpans.filter { $0.duration >= config.minSilenceDuration }.count
            : 0

        let cues = buildCaptionCues(
            tokens: tokens,
            clauses: clauses,
            keepSegments: keepSegments,
            config: config
        )

        return EditPlan(
            originalDuration: duration,
            outputDuration: keepSegments.last?.outputEnd ?? 0,
            keepSegments: keepSegments,
            captionCues: cues,
            cutSilenceCount: cutSilenceCount,
            cutFillerCount: cutFillerCount,
            cutNGClauseCount: cutNGClauseCount
        )
    }

    // MARK: - Helpers

    private static func makeClause(indices: [Int], tokens: [WordToken]) -> TranscriptClause {
        let s = indices.first.map { tokens[$0].start } ?? 0
        let e = indices.last.map { tokens[$0].end } ?? s
        return TranscriptClause(tokenIndices: indices, start: s, end: e)
    }

    private static func normalizedPlainText(clause: TranscriptClause, tokens: [WordToken]) -> String {
        var out = ""
        for idx in clause.tokenIndices {
            let t = tokens[idx]
            if t.isPunctuationOnly { continue }
            out += t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    private static func phoneticNormalized(clause: TranscriptClause, tokens: [WordToken]) -> [Character] {
        let plain = normalizedPlainText(clause: clause, tokens: tokens).lowercased()
        var chars: [Character] = []
        for ch in plain {
            if ch.isWhitespace || ch.isPunctuation { continue }
            chars.append(phoneticMap[ch] ?? ch)
        }
        return chars
    }

    public static func isLikelyNGRetake(earlier: [Character], later: [Character]) -> Bool {
        let n = earlier.count
        let m = later.count
        guard n >= 4, m >= 4 else { return false }

        // 1. Shared prefix check (speaker started a sentence, aborted, and restarted the same sentence)
        var commonPrefix = 0
        for k in 0..<min(n, m) {
            if earlier[k] == later[k] {
                commonPrefix += 1
            } else {
                break
            }
        }
        if commonPrefix >= 4 && m >= n - 1 {
            return true
        }

        // 2. Normalized Levenshtein similarity >= 0.65
        let dist = editDistance(earlier, later)
        let maxLen = Double(max(n, m))
        let similarity = 1.0 - (Double(dist) / maxLen)
        return similarity >= 0.65
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        let n = a.count
        let m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[m]
    }

    private static func invertSilences(
        silences: [SilenceSpan],
        duration: Double,
        pad: Double
    ) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var cursor: Double = 0
        for s in silences {
            let cutStart = min(duration, s.start + pad)
            let cutEnd = max(cutStart, s.end - pad)
            if cutEnd - cutStart < 0.05 { continue }
            if cutStart > cursor + 0.04 {
                result.append((cursor, cutStart))
            }
            cursor = cutEnd
        }
        if duration > cursor + 0.04 {
            result.append((cursor, duration))
        }
        return result
    }

    private static func buildKeepSegments(from intervals: [(Double, Double)]) -> [KeepSegment] {
        var out: [KeepSegment] = []
        var accOut: Double = 0
        for (s, e) in intervals where e - s >= 0.03 {
            let dur = e - s
            out.append(
                KeepSegment(
                    sourceStart: s,
                    sourceEnd: e,
                    outputStart: accOut,
                    outputEnd: accOut + dur
                )
            )
            accOut += dur
        }
        return out
    }

    private static func mapTime(_ srcTime: Double, segments: [KeepSegment]) -> Double? {
        for seg in segments {
            if srcTime >= seg.sourceStart - 0.05 && srcTime <= seg.sourceEnd + 0.05 {
                let clamped = min(max(seg.sourceStart, srcTime), seg.sourceEnd)
                return seg.outputStart + (clamped - seg.sourceStart)
            }
        }
        return nil
    }

    private static func buildCaptionCues(
        tokens: [WordToken],
        clauses: [TranscriptClause],
        keepSegments: [KeepSegment],
        config: CutWordConfig
    ) -> [CaptionCue] {
        let maxChars = max(8, config.maxCaptionCharsPerLine)
        var cues: [CaptionCue] = []
        var cueIndex = 1

        for clause in clauses {
            var chunkWords: [CaptionWordTiming] = []
            var chunkCharCount = 0

            let flushChunk = {
                guard !chunkWords.isEmpty else { return }
                let s = chunkWords.first!.outputStart
                let e = max(s + 0.12, chunkWords.last!.outputEnd)
                cues.append(
                    CaptionCue(
                        index: cueIndex,
                        outputStart: s,
                        outputEnd: e,
                        words: chunkWords
                    )
                )
                cueIndex += 1
                chunkWords.removeAll(keepingCapacity: true)
                chunkCharCount = 0
            }

            for tIdx in clause.tokenIndices {
                let tok = tokens[tIdx]
                if tok.isPunctuationOnly { continue }
                if tok.effectiveCutReason(
                    removeFillers: config.removeFillers,
                    removeNGRepeats: config.removeNGRepeats
                ) != nil {
                    continue
                }
                guard let outStart = mapTime(tok.start, segments: keepSegments),
                      let outEnd = mapTime(tok.end, segments: keepSegments) else {
                    continue
                }
                let cleanText = tok.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanText.isEmpty { continue }

                if chunkCharCount + cleanText.count > maxChars && !chunkWords.isEmpty {
                    flushChunk()
                }
                chunkWords.append(
                    CaptionWordTiming(
                        text: cleanText,
                        outputStart: outStart,
                        outputEnd: max(outStart + 0.04, outEnd)
                    )
                )
                chunkCharCount += cleanText.count
            }
            flushChunk()
        }

        // Ensure cues never overlap in output timeline
        if cues.count >= 2 {
            for i in 0..<(cues.count - 1) {
                if cues[i].outputEnd > cues[i + 1].outputStart {
                    cues[i] = CaptionCue(
                        id: cues[i].id,
                        index: cues[i].index,
                        outputStart: cues[i].outputStart,
                        outputEnd: max(cues[i].outputStart + 0.06, cues[i + 1].outputStart - 0.01),
                        words: cues[i].words
                    )
                }
            }
        }
        return cues
    }

    private static func isPureFillerPhrase(_ plain: String) -> Bool {
        let lower = plain.lowercased()
        if singleFillers.contains(lower) || multiCharFillers.contains(lower) {
            return true
        }
        var rem = lower
        for phrase in multiCharFillers.sorted(by: { $0.count > $1.count }) {
            rem = rem.replacingOccurrences(of: phrase, with: "")
        }
        for tok in singleFillers.sorted(by: { $0.count > $1.count }) {
            rem = rem.replacingOccurrences(of: tok, with: "")
        }
        return rem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !lower.isEmpty
    }
}
