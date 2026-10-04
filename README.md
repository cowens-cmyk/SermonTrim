# Sermon Trim

A small, single-purpose Mac app: trim a sermon video, add a fade in/out (picture and audio), and export **without re-encoding the whole file**.

## Build and run
```bash
brew install xcodegen          # once
xcodegen generate
xcodebuild -project SermonTrim.xcodeproj -scheme SermonTrim -configuration Release build
```
Or open `SermonTrim.xcodeproj` in Xcode and press Run. Requires macOS 26+ and Xcode 26+ (built with Xcode 27).
Command-line harness: `smarttrim <file> <in> <out> --start black:0.5 --end black:3` (scheme `smarttrim`).
Tests: `xcodebuild -project SermonTrim.xcodeproj -scheme SermonTrim test`.

## How the smart render works
Fades need re-encoded pixels, but only for the frames inside the fade.

```
output = [ head: re-encoded ][ middle: copied byte-for-byte ][ tail: re-encoded ]
```
* **Head:** from the In point to the next IDR keyframe (past the fade-in, if any).
* **Middle:** the original compressed H.264/HEVC samples, untouched.
* **Tail:** from the last IDR keyframe before the fade-out to the Out point.
* Head/tail are re-encoded with the source's codec, resolution, frame rate, colour tags and ~1.5x its bitrate, then all
  pieces are written into one file with continuous timestamps. Cut points are verified to be true IDR frames.
* **Audio** is decoded, gain-ramped, and re-encoded as AAC at about the source bitrate (small, fast). A 12 ms anti-click
  ramp is always applied at the cut points.
* After every export the app compares input vs output (codec, size, bitrate) and warns if the file grew by more than 15%.

Measured on a real 91-minute 1080p60 Resi download (2.72 GB): trim + 0.5 s fade-in + 3 s fade-out gave 2.71 GB (99.9%)
in about 45 s (92 s with a simultaneous full decode check); the copied middle was byte-identical packet-for-packet.

## Auto-detect (all on-device)
1. Audio is extracted and transcribed with Apple's `SpeechAnalyzer` (cached per file in Application Support).
2. Phrase matching finds candidate starts ("good morning", "turn with me", "you may be seated"...) and ends ("amen",
   "in Jesus' name", "worship with us"...), weighted by gaps of silence/music and by sustained sermon-like speech.
3. Apple's on-device language model (Foundation Models) picks the exact sentence around each candidate.
4. Suggestions are placed on the timeline as markers. Nothing is applied until you click **Use** / **Use best guess**.
   Out = last word + wait (default 5 s) + fade duration, so the fade starts after the quiet hold.
Phrase lists and the wait time are editable in Settings (⌘,).

## Keys
Space play/pause · I / O set In / Out · ← → frame step · , . ±1 s · **⌘B Blade** at playhead ([ cut before, ] cut after) · ⌘E export · ⌘O open

## Updating the installed app
After pulling changes (or when a new version is pushed), run `Scripts/update.sh`. It pulls, rebuilds and replaces
`/Applications/Sermon Trim.app`. Settings and cached transcripts are kept.

**In the app:** *Sermon Trim ▸ Check for Updates…* compares the installed version with GitHub (it also checks quietly a few
seconds after launch). *Update Now* opens Terminal, runs `Scripts/update.sh`, and reopens the updated app.

## Changelog
- Added in-app update check.
