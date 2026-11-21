import Foundation
import CutWordCore

@main
struct CutWordCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = args.first else {
            printHelp()
            return
        }

        do {
            switch subcommand {
            case "help", "--help", "-h":
                printHelp()
            case "demo":
                let outPath = optionValue("--out", in: args) ?? "./cutword-raw-demo.mp4"
                let url = URL(fileURLWithPath: outPath)
                fputs("🎬 正在本地合成实测口播废片（含静音气口、口癖「嗯」与 NG 重录废句）...\n", stderr)
                _ = try await SampleVideoBuilder.generateBuiltInDemoVideo(to: url)
                print(url.path)
            case "analyze":
                guard args.count >= 2 else {
                    fputs("错误：请指定媒体文件路径。用法：cutword analyze <video.mp4> [--locale zh-CN] [--json]\n", stderr)
                    exit(1)
                }
                let inputURL = URL(fileURLWithPath: args[1])
                let locale = optionValue("--locale", in: args) ?? "zh-CN"
                let emitJSON = args.contains("--json")
                let cfg = parseConfig(from: args)

                let analysis = try await CutWordPipeline.analyzeMedia(
                    url: inputURL,
                    localeIdentifier: locale,
                    config: cfg
                )
                let plan = SmartCutDetector.compileEditPlan(
                    tokens: analysis.tokens,
                    clauses: analysis.clauses,
                    silenceSpans: analysis.silenceSpans,
                    duration: analysis.duration,
                    config: cfg
                )

                if emitJSON {
                    struct Report: Codable {
                        let analysis: MediaAnalysisResult
                        let plan: EditPlan
                    }
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try enc.encode(Report(analysis: analysis, plan: plan))
                    print(String(data: data, encoding: .utf8) ?? "{}")
                } else {
                    print(String(format: "原片时长: %.2fs -> 精剪时长: %.2fs (省去 %.1f%%)",
                                 plan.originalDuration, plan.outputDuration, plan.savedPercent))
                    print("切除气口: \(plan.cutSilenceCount) 处 | 口癖词: \(plan.cutFillerCount) 个 | NG 重录分句: \(plan.cutNGClauseCount) 句")
                    print("生成字幕: \(plan.captionCues.count) 条")
                    for cue in plan.captionCues {
                        print(String(format: "  [%05.2f -> %05.2f] %@", cue.outputStart, cue.outputEnd, cue.plainText))
                    }
                }
            case "auto":
                guard args.count >= 2 else {
                    fputs("错误：请指定输入视频路径。用法：cutword auto <raw.mp4> --out <clean.mp4> [--srt out.srt] [--fcpxml out.fcpxml]\n", stderr)
                    exit(1)
                }
                let inputURL = URL(fileURLWithPath: args[1])
                let locale = optionValue("--locale", in: args) ?? "zh-CN"
                let cfg = parseConfig(from: args)

                let analysis = try await CutWordPipeline.analyzeMedia(
                    url: inputURL,
                    localeIdentifier: locale,
                    config: cfg,
                    onProgress: { msg in fputs("⏳ \(msg)\n", stderr) }
                )
                let plan = SmartCutDetector.compileEditPlan(
                    tokens: analysis.tokens,
                    clauses: analysis.clauses,
                    silenceSpans: analysis.silenceSpans,
                    duration: analysis.duration,
                    config: cfg
                )

                if let outMP4 = optionValue("--out", in: args) {
                    let outURL = URL(fileURLWithPath: outMP4)
                    fputs("🚀 正在硬件加速导出精剪 MP4 (\(cfg.burnCaptions ? "含动态高亮字幕" : "纯净无字幕"))...\n", stderr)
                    try await VideoExporter.exportMP4(
                        sourceURL: inputURL,
                        destinationURL: outURL,
                        plan: plan,
                        burnCaptions: cfg.burnCaptions
                    )
                    fputs("✅ 已导出视频: \(outURL.path)\n", stderr)
                }

                if let srtPath = optionValue("--srt", in: args) {
                    let srt = SubtitleExporter.formatSRT(cues: plan.captionCues)
                    try srt.write(toFile: srtPath, atomically: true, encoding: .utf8)
                    fputs("✅ 已导出 SRT 字幕: \(srtPath)\n", stderr)
                }

                if let fcpxmlPath = optionValue("--fcpxml", in: args) {
                    let timeline = try await VideoExporter.buildComposition(
                        sourceURL: inputURL,
                        plan: plan,
                        burnCaptions: false
                    )
                    let xml = SubtitleExporter.formatFCPXML(
                        sourceURL: inputURL,
                        projectName: inputURL.deletingPathExtension().lastPathComponent,
                        renderWidth: Int(timeline.renderSize.width.rounded()),
                        renderHeight: Int(timeline.renderSize.height.rounded()),
                        plan: plan
                    )
                    try xml.write(toFile: fcpxmlPath, atomically: true, encoding: .utf8)
                    fputs("✅ 已导出 FCPXML 工程: \(fcpxmlPath)\n", stderr)
                }

                print(String(format: "🎉 处理完成：%.2fs -> %.2fs（精简 %.1f%%）",
                             plan.originalDuration, plan.outputDuration, plan.savedPercent))
            default:
                fputs("未知命令：\(subcommand)\n", stderr)
                printHelp()
                exit(1)
            }
        } catch {
            fputs("❌ 执行失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func optionValue(_ flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func parseConfig(from args: [String]) -> CutWordConfig {
        var cfg = CutWordConfig()
        if let minSil = optionValue("--min-silence", in: args), let v = Double(minSil) {
            cfg.minSilenceDuration = v
        }
        if let dbStr = optionValue("--silence-db", in: args), let v = Float(dbStr) {
            cfg.silenceThresholdDb = v
        }
        if let padStr = optionValue("--padding", in: args), let v = Double(padStr) {
            cfg.breathPaddingSec = v
        }
        if args.contains("--keep-silences") { cfg.removeSilences = false }
        if args.contains("--keep-fillers") { cfg.removeFillers = false }
        if args.contains("--keep-ng") { cfg.removeNGRepeats = false }
        if args.contains("--no-burn-captions") { cfg.burnCaptions = false }
        return cfg
    }

    private static func printHelp() {
        print("""
        剪字 CutWord — 100% 本地离线 macOS 口播废片文字剪辑与字幕工具 (MIT Open Source)

        用法:
          cutword demo [--out ./raw-demo.mp4]
              在本地生成一条带静音气口、口癖与 NG 重录废句的实测口播样片

          cutword analyze <input.mp4> [--locale zh-CN] [--json]
              使用 Apple Neural Engine 离线逐字识别并输出精剪报告

          cutword auto <input.mp4> --out <clean.mp4> [--srt <clean.srt>] [--fcpxml <timeline.fcpxml>]
              一键自动切气口、删口癖、删 NG 重复废句，并硬件加速导出动态高亮字幕 MP4 / SRT / FCPXML

        可选参数:
          --locale <id>          语音识别语言（默认 zh-CN，支持 en-US / zh-TW / ja-JP 等）
          --min-silence <sec>    最短切除气口时长（默认 0.45）
          --silence-db <dbfs>    静音分贝阈值（默认 -36.0）
          --padding <sec>        语句前后自然呼吸缓冲（默认 0.12）
          --no-burn-captions     导出纯净无字幕 MP4（适合配合 --srt 拖入剪映换花字）
          --keep-fillers         保留口癖词（嗯/啊/那个）
          --keep-ng              保留 NG 重录废句
        """)
    }
}
