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

## Automation
Headless, with JSON on stdout (progress on stderr; exit 0 done, 1 failed, 2 bad arguments):
```bash
# Transcribe (cached) and suggest start/end. Each candidate has its time, sentence, the words before/after it and why.
smarttrim detect "Service.mp4" --json [--no-ai] [--tail 5] [--fade-out black:3]
# Export a trim. Timecodes use the video's own frame rate; MM:SS or seconds also work.
smarttrim trim "Service.mp4" --in 00:44:01:20 --out 01:23:08:07 --fade-out black:3 \
    -o "~/Desktop/(Students) Advent (11.18.26).mp4" [--overwrite] --json [--result result.json]
```
Without `--overwrite` an existing name gets " 2". The result lists the output path, duration, size, share re-encoded and
elapsed time. Files are staged outside iCloud-synced folders and moved in when finished, like the app does.

Opening the app on a video (the window loads it, applies the points, and can start auto-detect):
```bash
open -a "Sermon Trim" "Service.mp4"
open "sermontrim://open?path=/Users/me/Desktop/Service.mp4&in=00:44:01:20&out=01:23:08:07&detect=1"
"/Applications/Sermon Trim.app/Contents/MacOS/Sermon Trim" "Service.mp4" --in 44:01 --out 1:23:08 --detect
```
Controls carry stable accessibility identifiers (`in-timecode`, `out-timecode`, `set-in`, `set-out`, `trim-length`,
`find-start-end`, `use-best-guess`, `transcript-search`, `transcript-line-<centiseconds>`, `play-pause`, `export`,
`choose-video`). The In/Out and search fields accept AXValue and AXConfirm.
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
   Starts also score for the shape of a service: sparse speech (songs, silence) turning into dense talk, the length of
   the talk that follows compared with the longest in the file, and following a prayer's "amen" or "be seated".
3. Apple's on-device language model (Foundation Models) picks the exact sentence around each candidate. It refines a
   candidate but can't outrank a better one (it reports ~100% confidence for nearly everything).
4. Suggestions are placed on the timeline as markers. Nothing is applied until you click **Use** / **Use best guess**.
   Out = last word + wait (default 5 s) + fade duration, so the fade starts after the quiet hold.
Phrase lists and the wait time are editable in Settings (⌘,).

## Sermon info and file naming
Click **Export**: the export starts right away and a **Sermon Details** window opens while it runs. Enter the **title**, **date**
(calendar; defaults to the Sunday closest to the video's date) and **speaker**, then **Save** (or *Save When Done*). The export is saved
to the Desktop (changeable) as `The Lord Sees (10.4.26).mp4`, the speaker becomes a **Finder tag** (so you can filter by speaker
in Finder). Several speakers: separate with commas. *Skip* saves with the original name and no tag. The original video
is never touched; without a title the file is saved as `<original name> - trimmed`.

## Also included
* **Live fade preview** — the player shows the fades (and audio ramps) as you adjust them. ⌘1 / ⌘2 play the start and end.
* **Waveform** on the timeline, so the silence around "amen" is easy to see.
* **Copy-vs-re-encode summary** next to Export ("Copies 98.1% as-is · re-encodes 5.6 s"). If a long stretch would have to be
  re-encoded (a source with no clean keyframes near your cuts) you get a warning first instead of a surprise.
* **Undo/redo (⌘Z)** for In/Out changes, and your usual fade settings are remembered.
* **Batch Auto-Trim… (⌥⌘B)**: queue several files; each is transcribed, detected, and exported next to the original.
  Results list the detected In/Out with *Open in Editor* for any file you want to check. CLI: `smarttrim batch <files>`.
* H.264 and HEVC (8-bit and 10-bit, closed-GOP) sources. Colour tags are carried through.

## Keys
Space play/pause · I / O set In / Out · ← → frame step · , . ±1 s · **⌘B Blade** at playhead ([ cut before, ] cut after) · ⌘E export · ⌘O open

## Releases (several Macs)
`Scripts/release.sh 1.1.0 "What changed"` builds the app, makes the DMG, tags the commit, and publishes a GitHub release with
the DMG attached. On any Mac without the source folder, *Sermon Trim ▸ Check for Updates…* finds the newest release,
downloads the DMG, verifies its checksum, bundle ID and signature, swaps the app in place and relaunches it.
The app is ad-hoc signed (not notarized): on a new Mac, right-click ▸ Open once. Updates the app downloads itself don't
trigger that warning again.

## Updating the installed app (the Mac with the source folder)
After pulling changes (or when a new version is pushed), run `Scripts/update.sh`. It pulls, rebuilds and replaces
`/Applications/Sermon Trim.app`. Settings and cached transcripts are kept.

**In the app:** *Sermon Trim ▸ Check for Updates…* compares the installed version with GitHub (it also checks quietly a few
seconds after launch). *Update Now* opens Terminal, runs `Scripts/update.sh`, and reopens the updated app.

## Changelog
- Added in-app update check.
