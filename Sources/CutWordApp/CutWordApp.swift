import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import AppKit
import CutWordCore

@MainActor
final class StudioViewModel: ObservableObject {
    @Published var sourceURL: URL? = nil
    @Published var isBusy: Bool = false
    @Published var statusMessage: String = "拖入任意口播视频 (.mp4 / .mov)，或点击「一键载入内置实测口播废片」立即体验"
    @Published var localeId: String = "zh-CN"

    @Published var config: CutWordConfig = CutWordConfig()
    @Published var analysis: MediaAnalysisResult? = nil
    @Published var plan: EditPlan? = nil

    @Published var player: AVPlayer = AVPlayer()
    @Published var previewCleanedTimeline: Bool = true
    @Published var editingTokenIndex: Int? = nil
    @Published var editingTokenText: String = ""

    private var rebuildPreviewTask: Task<Void, Never>? = nil

    func loadBuiltInDemo() {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "🎬 正在本地合成含气口、口癖「嗯」与 NG 重录废句的实测样片..."

        Task {
            do {
                let demoURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CutWord-Demo-Raw.mp4")
                _ = try await SampleVideoBuilder.generateBuiltInDemoVideo(to: demoURL)
                await openMediaInternal(url: demoURL)
            } catch {
                self.statusMessage = "❌ 生成样片失败：\(error.localizedDescription)"
                self.isBusy = false
            }
        }
    }

    func openMedia(url: URL) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await openMediaInternal(url: url)
        }
    }

    private func openMediaInternal(url: URL) async {
        self.sourceURL = url
        self.statusMessage = "⏳ 正在使用 Apple Neural Engine 离线逐字识别..."
        let locale = self.localeId
        let cfg = self.config

        do {
            let res = try await CutWordPipeline.analyzeMedia(
                url: url,
                localeIdentifier: locale,
                config: cfg,
                onProgress: { msg in
                    Task { @MainActor in
                        self.statusMessage = msg
                    }
                }
            )
            self.analysis = res
            recomputePlanAndPreview()
            if let p = self.plan {
                self.statusMessage = String(
                    format: "✅ 识别完成：原片 %.1fs → 精剪后 %.1fs（自动省去 %.0f%% 废片）",
                    p.originalDuration, p.outputDuration, p.savedPercent
                )
            }
        } catch {
            self.statusMessage = "❌ 分析失败：\(error.localizedDescription)"
        }
        self.isBusy = false
    }

    func recomputePlanAndPreview() {
        guard let currentAnalysis = analysis else { return }
        let newPlan = SmartCutDetector.compileEditPlan(
            tokens: currentAnalysis.tokens,
            clauses: currentAnalysis.clauses,
            silenceSpans: currentAnalysis.silenceSpans,
            duration: currentAnalysis.duration,
            config: config
        )
        self.plan = newPlan
        schedulePreviewRebuild()
    }

    func toggleTokenCut(at index: Int) {
        guard var res = analysis, res.tokens.indices.contains(index) else { return }
        let tok = res.tokens[index]
        let currentlyCut = tok.effectiveCutReason(
            removeFillers: config.removeFillers,
            removeNGRepeats: config.removeNGRepeats
        ) != nil
        res.tokens[index].userOverrideKeep = currentlyCut ? true : false
        self.analysis = res
        recomputePlanAndPreview()
    }

    func toggleClauseCut(_ clause: TranscriptClause) {
        guard var res = analysis else { return }
        let spoken = clause.tokenIndices.filter { !res.tokens[$0].isPunctuationOnly }
        guard !spoken.isEmpty else { return }
        let allCut = spoken.allSatisfy { idx in
            res.tokens[idx].effectiveCutReason(
                removeFillers: config.removeFillers,
                removeNGRepeats: config.removeNGRepeats
            ) != nil
        }
        for idx in clause.tokenIndices {
            res.tokens[idx].userOverrideKeep = allCut ? true : false
        }
        self.analysis = res
        recomputePlanAndPreview()
    }

    func commitTokenTextEdit() {
        guard let idx = editingTokenIndex,
              var res = analysis,
              res.tokens.indices.contains(idx) else {
            editingTokenIndex = nil
            return
        }
        let trimmed = editingTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            res.tokens[idx].text = trimmed
            self.analysis = res
            recomputePlanAndPreview()
        }
        editingTokenIndex = nil
    }

    func resetAllManualOverrides() {
        guard var res = analysis else { return }
        for i in res.tokens.indices {
            res.tokens[i].userOverrideKeep = nil
        }
        self.analysis = res
        recomputePlanAndPreview()
    }

    func seekToSourceTime(_ srcSec: Double) {
        if previewCleanedTimeline, let p = plan, let outSec = p.mapSourceToOutputTime(srcSec) {
            player.seek(to: CMTime(seconds: outSec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else if !previewCleanedTimeline {
            player.seek(to: CMTime(seconds: srcSec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func schedulePreviewRebuild() {
        rebuildPreviewTask?.cancel()
        guard let url = sourceURL, let currentPlan = plan else { return }
        let useCleaned = previewCleanedTimeline
        let burn = config.burnCaptions

        rebuildPreviewTask = Task {
            player.pause()
            if !useCleaned {
                let item = AVPlayerItem(url: url)
                player.replaceCurrentItem(with: item)
                return
            }
            guard !currentPlan.keepSegments.isEmpty else { return }
            do {
                let composed = try await VideoExporter.buildComposition(
                    sourceURL: url,
                    plan: currentPlan,
                    burnCaptions: burn
                )
                if Task.isCancelled { return }
                let item = AVPlayerItem(asset: composed.composition)
                item.videoComposition = composed.videoComposition
                item.audioMix = composed.audioMix
                player.replaceCurrentItem(with: item)
                if let seekIdx = CommandLine.arguments.firstIndex(of: "--seek-preview"),
                   CommandLine.arguments.indices.contains(seekIdx + 1),
                   let sec = Double(CommandLine.arguments[seekIdx + 1]) {
                    await player.seek(to: CMTime(seconds: sec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                } else if let firstCue = currentPlan.captionCues.first {
                    await player.seek(
                        to: CMTime(seconds: firstCue.outputStart + 0.08, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            } catch {
                // Keep previous item if transient rebuild fails
            }
        }
    }

    func exportSubtitledMP4() {
        guard let src = sourceURL, let currentPlan = plan else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(src.deletingPathExtension().lastPathComponent)-精剪字幕版.mp4"
        guard panel.runModal() == .OK, let dst = panel.url else { return }

        isBusy = true
        statusMessage = "🚀 正在通过 VideoToolbox 硬件加速导出精剪字幕成片..."
        let burn = config.burnCaptions
        Task {
            do {
                try await VideoExporter.exportMP4(
                    sourceURL: src,
                    destinationURL: dst,
                    plan: currentPlan,
                    burnCaptions: burn
                )
                self.statusMessage = "✅ 成片已导出：\(dst.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([dst])
            } catch {
                self.statusMessage = "❌ 导出失败：\(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func exportPureMP4AndSRT() {
        guard let src = sourceURL, let currentPlan = plan else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(src.deletingPathExtension().lastPathComponent)-精剪无字幕.mp4"
        panel.message = "将同时在同目录生成配套 .srt 字幕文件（可直接免费拖入剪映/PR/达芬奇换花字）"
        guard panel.runModal() == .OK, let dstMP4 = panel.url else { return }
        let dstSRT = dstMP4.deletingPathExtension().appendingPathExtension("srt")

        isBusy = true
        statusMessage = "🚀 正在导出纯净精剪 MP4 与剪映免会员 .srt 字幕..."
        Task {
            do {
                try await VideoExporter.exportMP4(
                    sourceURL: src,
                    destinationURL: dstMP4,
                    plan: currentPlan,
                    burnCaptions: false
                )
                let srtContent = SubtitleExporter.formatSRT(cues: currentPlan.captionCues)
                try srtContent.write(to: dstSRT, atomically: true, encoding: .utf8)
                self.statusMessage = "✅ 已导出纯净 MP4 + \(dstSRT.lastPathComponent)（直接拖入剪映即可免会员加花字）"
                NSWorkspace.shared.activateFileViewerSelecting([dstMP4, dstSRT])
            } catch {
                self.statusMessage = "❌ 导出失败：\(error.localizedDescription)"
            }
            self.isBusy = false
        }
    }

    func exportFCPXMLFile() {
        guard let src = sourceURL, let currentPlan = plan else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(src.deletingPathExtension().lastPathComponent)-CutWord.fcpxml"
        guard panel.runModal() == .OK, let dst = panel.url else { return }

        Task {
            do {
                let timeline = try await VideoExporter.buildComposition(
                    sourceURL: src,
                    plan: currentPlan,
                    burnCaptions: false
                )
                let xml = SubtitleExporter.formatFCPXML(
                    sourceURL: src,
                    projectName: src.deletingPathExtension().lastPathComponent,
                    renderWidth: Int(timeline.renderSize.width.rounded()),
                    renderHeight: Int(timeline.renderSize.height.rounded()),
                    plan: currentPlan
                )
                try xml.write(to: dst, atomically: true, encoding: .utf8)
                self.statusMessage = "✅ 已导出无损时间轴工程：\(dst.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([dst])
            } catch {
                self.statusMessage = "❌ FCPXML 导出失败：\(error.localizedDescription)"
            }
        }
    }
}

struct WaveformTimelineView: View {
    let peaks: [Float]
    let duration: Double
    let keepSegments: [KeepSegment]
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let count = max(1, peaks.count)
            let barW = max(1.5, (geo.size.width / CGFloat(count)) - 1.2)

            HStack(alignment: .center, spacing: 1.2) {
                ForEach(0..<count, id: \.self) { idx in
                    let t = (Double(idx) + 0.5) / Double(count) * max(0.01, duration)
                    let isKept = keepSegments.contains { t >= $0.sourceStart && t <= $0.sourceEnd }
                    let h = max(4, CGFloat(peaks[idx]) * (geo.size.height - 8))

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isKept
                              ? Color(red: 0.16, green: 0.82, blue: 0.56)
                              : Color(red: 0.94, green: 0.30, blue: 0.34).opacity(0.65))
                        .frame(width: barW, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { val in
                        let ratio = max(0, min(1, val.location.x / max(1, geo.size.width)))
                        onSeek(Double(ratio) * duration)
                    }
            )
        }
    }
}

struct StudioMainView: View {
    @StateObject private var vm = StudioViewModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            topHeaderBar
            Divider().overlay(Color.white.opacity(0.08))

            if vm.analysis == nil {
                emptyDropZone
            } else {
                HSplitView {
                    leftPlayerAndWaveformPane
                        .frame(minWidth: 460, idealWidth: 540)
                    rightTranscriptEditorPane
                        .frame(minWidth: 460, idealWidth: 560)
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            bottomExportBar
        }
        .background(Color(red: 0.05, green: 0.07, blue: 0.11))
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL, .movie, .mpeg4Movie, .quickTimeMovie], isTargeted: $isDropTargeted) { providers in
            guard let first = providers.first else { return false }
            _ = first.loadObject(ofClass: URL.self) { url, _ in
                if let validURL = url {
                    Task { @MainActor in
                        vm.openMedia(url: validURL)
                    }
                }
            }
            return true
        }
        .sheet(isPresented: Binding(
            get: { vm.editingTokenIndex != nil },
            set: { if !$0 { vm.editingTokenIndex = nil } }
        )) {
            VStack(spacing: 14) {
                Text("修正识别字幕错别字")
                    .font(.headline)
                TextField("输入正确字词", text: $vm.editingTokenText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { vm.commitTokenTextEdit() }
                HStack(spacing: 12) {
                    Button("取消") { vm.editingTokenIndex = nil }
                    Button("保存并同步字幕") { vm.commitTokenTextEdit() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .onOpenURL { url in
            vm.openMedia(url: url)
        }
        .onAppear {
            if let openIdx = CommandLine.arguments.firstIndex(of: "--open"),
               CommandLine.arguments.indices.contains(openIdx + 1) {
                let fileURL = URL(fileURLWithPath: CommandLine.arguments[openIdx + 1])
                vm.openMedia(url: fileURL)
            } else if CommandLine.arguments.contains("--demo-auto-load") {
                vm.loadBuiltInDemo()
            }
        }
    }

    private var topHeaderBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "scissors.badge.ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.15))
                Text("剪字 CutWord")
                    .font(.system(size: 17, weight: .bold))
                Text("MIT 开源 · Apple Neural Engine 离线引擎")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.emeraldBadge.opacity(0.18))
                    .foregroundStyle(Color.emeraldBadge)
                    .clipShape(Capsule())
            }

            Spacer()

            Picker("识别语言", selection: $vm.localeId) {
                Text("中文普通话 (zh-CN)").tag("zh-CN")
                Text("English (en-US)").tag("en-US")
                Text("繁體中文 (zh-TW)").tag("zh-TW")
            }
            .pickerStyle(.menu)
            .frame(width: 235)

            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let u = panel.url {
                    vm.openMedia(url: u)
                }
            } label: {
                Label("导入口播视频", systemImage: "folder.badge.plus")
            }
            .disabled(vm.isBusy)

            Button {
                vm.loadBuiltInDemo()
            } label: {
                Label("一键载入实测废片", systemImage: "sparkles.tv")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.15, green: 0.68, blue: 0.48))
            .disabled(vm.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color(red: 0.07, green: 0.09, blue: 0.15))
    }

    private var emptyDropZone: some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 52))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.15))

                Text("像删 Word 文档一样剪口播视频")
                    .font(.system(size: 26, weight: .bold))

                Text("0 Python · 0 模型下载 · 0 API Key · 100% 本地离线\n自动切掉冷场气口、口癖词（嗯/啊/那个）与「说错重录的 NG 废句」，一键直出动态高亮字幕 MP4 或剪映免会员 SRT")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 580)

                HStack(spacing: 14) {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
                        if panel.runModal() == .OK, let u = panel.url {
                            vm.openMedia(url: u)
                        }
                    } label: {
                        Label("选择本地 MP4 / MOV 口播原片", systemImage: "video.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        vm.loadBuiltInDemo()
                    } label: {
                        Label("一键生成并载入实测口播废片", systemImage: "play.rectangle.on.rectangle")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 6)
            }
            .padding(44)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.white.opacity(isDropTargeted ? 0.09 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(
                                isDropTargeted ? Color.emeraldBadge : Color.white.opacity(0.14),
                                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                            )
                    )
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftPlayerAndWaveformPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = vm.plan {
                HStack {
                    HStack(spacing: 8) {
                        Text(String(format: "原片 %.1fs", p.originalDuration))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "精剪后 %.1fs", p.outputDuration))
                            .fontWeight(.bold)
                            .foregroundStyle(Color.emeraldBadge)
                        Text(String(format: "省去 %.0f%%", p.savedPercent))
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(red: 1.0, green: 0.78, blue: 0.15).opacity(0.2))
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.15))
                            .clipShape(Capsule())
                    }
                    .font(.system(size: 13))

                    Spacer()

                    Toggle("实时预览剪后跳接效果", isOn: $vm.previewCleanedTimeline)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: vm.previewCleanedTimeline) { _, _ in
                            vm.schedulePreviewRebuild()
                        }
                }
            }

            VideoPlayer(player: vm.player)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .frame(minHeight: 270)

            if let res = vm.analysis, let p = vm.plan {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("16kHz 声学波形图（绿色=保留干货 · 红色=自动切除的气口/口癖/NG 句）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("气口 -\(p.cutSilenceCount) | 口癖 -\(p.cutFillerCount) | NG重录 -\(p.cutNGClauseCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.96, green: 0.42, blue: 0.45))
                    }

                    WaveformTimelineView(
                        peaks: res.waveformPeaks,
                        duration: res.duration,
                        keepSegments: p.keepSegments,
                        onSeek: { t in vm.seekToSourceTime(t) }
                    )
                    .frame(height: 62)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
    }

    private var rightTranscriptEditorPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Smart Cut Filter Controls
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Toggle("✂️ 自动切气口", isOn: $vm.config.removeSilences)
                        .onChange(of: vm.config.removeSilences) { _, _ in vm.recomputePlanAndPreview() }
                    Toggle("🧹 删口癖(嗯/啊)", isOn: $vm.config.removeFillers)
                        .onChange(of: vm.config.removeFillers) { _, _ in vm.recomputePlanAndPreview() }
                    Toggle("🔁 删 NG 重录废句", isOn: $vm.config.removeNGRepeats)
                        .onChange(of: vm.config.removeNGRepeats) { _, _ in vm.recomputePlanAndPreview() }
                    Toggle("🔥 烧录高亮大字字幕", isOn: $vm.config.burnCaptions)
                        .onChange(of: vm.config.burnCaptions) { _, _ in vm.schedulePreviewRebuild() }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5, weight: .medium))

                HStack(spacing: 12) {
                    Text(String(format: "最短切气口: %.2fs", vm.config.minSilenceDuration))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 115, alignment: .leading)
                    Slider(value: $vm.config.minSilenceDuration, in: 0.25...1.20, step: 0.05) { editing in
                        if !editing { vm.recomputePlanAndPreview() }
                    }
                    Button("恢复自动标记") {
                        vm.resetAllManualOverrides()
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("💡 点击任意字词即可「划除 / 恢复」对应视频片段；右键字词可修正同音错别字")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let res = vm.analysis {
                        ForEach(res.clauses) { clause in
                            clauseRow(clause: clause, tokens: res.tokens)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
    }

    private func clauseRow(clause: TranscriptClause, tokens: [WordToken]) -> some View {
        let activeReasons = clause.tokenIndices.compactMap { idx in
            tokens[idx].effectiveCutReason(
                removeFillers: vm.config.removeFillers,
                removeNGRepeats: vm.config.removeNGRepeats
            )
        }
        let spokenCount = clause.tokenIndices.filter { !tokens[$0].isPunctuationOnly }.count
        let isEntireClauseCut = spokenCount > 0 && activeReasons.count >= spokenCount

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    vm.seekToSourceTime(clause.start)
                } label: {
                    Text(String(format: "%05.2fs", clause.start))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(red: 0.58, green: 0.77, blue: 0.99))
                }
                .buttonStyle(.plain)

                if let reason = clause.autoReason {
                    Text(reason.labelZh)
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.red.opacity(0.22))
                        .foregroundStyle(Color(red: 0.98, green: 0.48, blue: 0.50))
                        .clipShape(Capsule())
                }

                Spacer()

                Button(isEntireClauseCut ? "恢复整句" : "整句划除") {
                    vm.toggleClauseCut(clause)
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .foregroundStyle(isEntireClauseCut ? Color.emeraldBadge : .secondary)
            }

            WrappingTokenFlow(
                indices: clause.tokenIndices,
                tokens: tokens,
                removeFillers: vm.config.removeFillers,
                removeNGRepeats: vm.config.removeNGRepeats,
                onTapToken: { idx in vm.toggleTokenCut(at: idx) },
                onEditToken: { idx in
                    vm.editingTokenText = tokens[idx].text
                    vm.editingTokenIndex = idx
                }
            )
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isEntireClauseCut ? Color.red.opacity(0.07) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isEntireClauseCut ? Color.red.opacity(0.26) : Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var bottomExportBar: some View {
        HStack(spacing: 12) {
            if vm.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(vm.statusMessage)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                vm.exportFCPXMLFile()
            } label: {
                Label("导出 FCPXML (达芬奇/FCP)", systemImage: "film.stack")
            }
            .disabled(vm.plan == nil || vm.isBusy)

            Button {
                vm.exportPureMP4AndSRT()
            } label: {
                Label("导出纯净 MP4 + SRT (直拖剪映免会员)", systemImage: "captions.bubble")
            }
            .disabled(vm.plan == nil || vm.isBusy)

            Button {
                vm.exportSubtitledMP4()
            } label: {
                Label("一键导出动态字幕成片 MP4", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.16, green: 0.72, blue: 0.50))
            .disabled(vm.plan == nil || vm.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color(red: 0.07, green: 0.09, blue: 0.15))
    }
}

struct WrappingTokenFlow: View {
    let indices: [Int]
    let tokens: [WordToken]
    let removeFillers: Bool
    let removeNGRepeats: Bool
    let onTapToken: (Int) -> Void
    let onEditToken: (Int) -> Void

    var body: some View {
        // Adaptive flow using native SwiftUI Layout
        FlowLayout(spacing: 4) {
            ForEach(indices, id: \.self) { idx in
                let tok = tokens[idx]
                let cutReason = tok.effectiveCutReason(
                    removeFillers: removeFillers,
                    removeNGRepeats: removeNGRepeats
                )
                let isCut = cutReason != nil

                Text(tok.text)
                    .font(.system(size: 14.5, weight: isCut ? .regular : .medium))
                    .strikethrough(isCut, color: Color.red.opacity(0.85))
                    .foregroundStyle(isCut ? Color.red.opacity(0.75) : Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isCut ? Color.red.opacity(0.16) : Color.white.opacity(0.08))
                    )
                    .onTapGesture {
                        if !tok.isPunctuationOnly {
                            onTapToken(idx)
                        }
                    }
                    .contextMenu {
                        Button("✏️ 修改此字词（纠错）") {
                            onEditToken(idx)
                        }
                        Button(isCut ? "✅ 恢复此片段" : "✂️ 剪除此片段") {
                            onTapToken(idx)
                        }
                    }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 420
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension Color {
    static let emeraldBadge = Color(red: 0.20, green: 0.84, blue: 0.60)
}

@main
struct CutWordMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("剪字 CutWord — 本地口播文字剪辑与字幕工作台") {
            StudioMainView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
