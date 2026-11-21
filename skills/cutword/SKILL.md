---
name: cutword
description: Edit talking-head videos (MP4/MOV) offline on Apple Silicon macOS by automatically cutting silences, Chinese/English filler words, and NG repeated bad takes, plus burning Karaoke subtitles or exporting calibrated .srt and FCPXML. Use when the user wants to clean up spoken video/audio, remove pauses or stutters, generate word-level subtitles, or export an edited timeline for Final Cut Pro / Premiere / DaVinci / CapCut.
---

# CutWord CLI Skill (`cutword`)

`CutWord` uses macOS native `SpeechAnalyzer` + `SpeechTranscriber` + `AVFoundation` on Apple Silicon (zero Python, zero Whisper weight downloads, zero cloud API keys, 100% offline).

## Installation Check

Check if `cutword` is installed:

```bash
which cutword || ls /Applications/CutWord.app/Contents/MacOS/cutword
```

If not installed on macOS 26+ (`arm64`), install via Homebrew:

```bash
brew install --cask --no-quarantine wang-builds/tap/cutword
```

## Core Commands

### 1. One-Click Auto Clean + Export (MP4 + SRT + FCPXML)

Automatically transcribes with character-level timestamps, removes silences (`>= 0.45s` while keeping `120ms` natural breath padding), strips filler words (`嗯`, `啊`, `那个`, `就是说`, `uh`, `um`), detects NG repeated bad takes, and exports hardware-accelerated MP4:

```bash
cutword auto input.mp4 \
  --out output_clean.mp4 \
  --srt output_clean.srt \
  --fcpxml output_clean.fcpxml \
  --json output_report.json
```

Useful flags:
- `--no-subtitles`: Export pure stitched MP4 without burned-in Karaoke captions (ideal when importing `output_clean.mp4` + `output_clean.srt` into CapCut / Jianying / Premiere).
- `--locale zh-CN` (default) or `--locale en-US`: Set speech recognition locale.
- `--min-silence 0.45`: Minimum silence gap in seconds to cut (default `0.45`).
- `--padding 0.12`: Breath padding kept around spoken words in seconds (default `0.12`).
- `--keep-fillers`: Keep filler words (`嗯/啊/那个`).
- `--keep-retakes`: Keep repeated NG takes.

### 2. Inspect Transcript & Cut Plan Only (JSON)

When you want to inspect what `CutWord` will cut before rendering video:

```bash
cutword analyze input.mp4 --json analysis.json
```

### 3. Generate Built-in Test Video

Generate a synthetic talking-head MP4 containing real Chinese speech, filler words, NG retakes, and long pauses for testing:

```bash
cutword demo --out sample_raw.mp4
```
