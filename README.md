# OldDV Rescue

DV tape capture and error analysis for **Mac OS X 10.6 Snow Leopard** (and 10.7 – 10.14),
modelled on [DVRescue](https://github.com/mipops/dvrescue). For personal use.

DVRescue itself does not run on 10.6. Its capture code needs AVFoundation (10.7+),
its GUI needs Qt 5/6 (10.13+), and the C++ code needs a toolchain far newer than Xcode 3.
OldDV Rescue re-implements the parts you need for a FireWire DV transfer station, using
only APIs that exist in Snow Leopard. It is written in plain C99 and Objective-C,
with no dependencies:

| DVRescue feature | OldDV Rescue |
|---|---|
| Capture from a FireWire DV camcorder/deck (`dvrescue device://0 -m out.dv`) | **Capture** tab. Uses QTKit on 10.6 and AVFoundation on 10.7+. Writes the raw DV stream byte for byte, like DVRescue. |
| Deck control (play, stop, rewind, FF, reverse) | Same AV/C commands, sent through `IOFireWireAVCLib` |
| Error analysis per frame (concealed video blocks/STA, audio error codes, time code / recording date / sequence / track number continuity, recording starts) | Same rules as DVRescue / MediaInfoLib, re-implemented in C |
| XML report (`*.dvrescue.xml`) | Same XML format and namespace, so the DVRescue tools can read it |
| "Rewind and retry" of bad sections (`--rewind-count`) | **Re-read sections with errors** option: rewinds by time code, captures each bad section again, then merges |
| Merge of several captures, block by block (`--merge`) | **Merge Takes** tab / `olddv -m` |
| `dvpackager` (split at each recording) | **Package** tab: one `.dv` per recording, optional `.mov` rewrap if you install ffmpeg |
| `dvloupe` / `dvplay` (block error map of a frame) | **Analyze** tab: error timeline, list of bad frames, block map and picture of each frame |

Not included: DeckLink/analog capture, closed caption export (SCC/SRT/WebVTT), MKV output,
and DVRescue's Qt player/GUI.

## Install

### Option A: prebuilt app

1. Copy `dist/OldDV-Rescue-1.0.0-mac.zip` to the Mac and double-click it.
2. Drag **OldDV Rescue.app** to *Applications*.
3. On 10.6 it just opens. On 10.8+ Gatekeeper may say the app is from an unidentified
   developer: right-click (Ctrl-click) the app, choose **Open**, then confirm once.

The prebuilt binary is 64-bit Intel, built for 10.6 (see *How the prebuilt app is made*).

### Option B: build it on your Mac

* **On 10.6:** install Xcode 3.2.6 (free download from developer.apple.com, "More downloads").
* **On 10.11:** install Xcode 7 or 8, or just the command line tools (`xcode-select --install`).

Then, in Terminal:

```bash
cd OldDV
```

```bash
./build.sh install
```

This builds `build/OldDV Rescue.app`, copies it to /Applications, and also builds the
command line tool `build/olddv`. A build on 10.11 includes both capture engines and runs
on 10.6 as well.

## Hardware setup

* Your late-2009 Mac mini has a **FireWire 800** (9-pin) port. Most camcorders have a small
  **4-pin DV** (FireWire 400) socket. Use a 9-pin-to-4-pin FireWire cable, or a
  9-to-6 adapter plus a 6-to-4 cable.
* Put the camcorder in **VCR / PLAY** mode (not camera mode). Connect before launching the
  app, or click **Refresh** / **Connect**.
* Quit iMovie, QuickTime Player and Final Cut while capturing: only one app can use the device.
* Disk space: about **13 GB per hour** of tape (3.6 MB/s). The internal 320 GB disk is fast enough.
* On a Core 2 Duo with 2 GB of RAM, the live preview is fine. If you see "dropped"
  warnings or the Mac feels slow, untick **Live picture preview**.

## Using it

### Capture

1. Choose the device (it connects automatically). The **Deck** line shows the transport
   state, and the time code updates when the tape plays.
2. Choose the folder and a file name (default `Tape_<date>`).
3. Options:
   * *play the tape when capture starts*: sends PLAY at start and STOP at the end.
   * *Finish when there is no signal for N seconds*: stops by itself at the end of the
     recorded part of the tape.
   * *Re-read sections with errors: N times*: after the first pass, the deck rewinds to each
     section that had errors (located by time code), plays it again and records it into
     `name.retry1.dv`, `name.retry2.dv`, and so on. All takes are then merged into
     `name.merged.dv`, keeping the best blocks of every take. This is DVRescue's
     "rewind count", run as a pass after the capture. It needs deck control and a tape with
     time code, which consumer DV always has.
4. **Start Capture**. The graph shows errors as they happen. Red bars mean concealed video
   blocks, orange bars mean audio errors, blue marks show a new recording on the tape, and
   yellow marks show a time code break.

Each `.dv` file gets a `.dv.dvrescue.xml` report next to it.
The raw `.dv` is your preservation master. Keep it even if you make a merged or packaged
version.

**Tip:** cleaning the heads, or simply capturing the same tape twice on two different
decks, then merging (*Merge Takes* tab), often recovers frames a single pass cannot.

### Analyze

Open any `.dv` file, or click **Analyze Capture** on the Capture tab. You get:

* a summary: format, time code range, frames with errors, recording starts;
* a clickable error timeline;
* the list of frames with issues;
* for the selected frame, a picture (decoded by QuickTime) and a **block map**. Each row of
  the map is a DIF sequence (a tape track). Red cells are concealed video blocks, orange
  cells are audio blocks containing error codes.

**Save XML** writes a DVRescue-compatible report. **Save CSV** writes a spreadsheet of the
frames with issues.

### Merge Takes

Add two or more captures of the same tape, choose an output file and click **Merge**.
Frames are lined up by absolute track number when the tape has it, otherwise by time code.
One-off glitches in time code or track number are ignored, so they don't break the
alignment. For each frame, the take with the fewest bad blocks is used, and each of its
bad blocks is replaced by a good copy of the same block from another take.

### Package

Splits a capture into one `.dv` per recording, and optionally at 4:3/16:9 or audio
changes and time code breaks. The parts open in QuickTime Player 7/X, iMovie '09 and
Final Cut. If you have an `ffmpeg` binary, tick the option to also get `.mov` files
(stream copy, no re-encoding).

## Command line

The command line tool is in `OldDV Rescue.app/Contents/Resources/olddv`, or at
`build/olddv` if you built it yourself:

```bash
olddv tape.dv -s
```

```bash
olddv tape.dv -x tape.dv.dvrescue.xml
```

```bash
olddv take1.dv take2.dv take3.dv -m merged.dv --merge-log merge.txt
```

```bash
olddv tape.dv --split parts/tape --by rec,format --min 25
```

* `-s`: print a summary.
* `-x`: write the XML report (DVRescue format).
* `-m`: merge takes, picking the best blocks of each.
* `--split`: write one file per recording.

`olddv --help` lists all options, including `--csv`.

## How faithful is it to DVRescue?

The analysis was checked against the real DVRescue (24.07 with MediaInfoLib 26.10, built
from source). The test files were DVRescue's own camcorder sample and ffmpeg-generated
NTSC/PAL DV, with randomly injected damage: concealed blocks, audio error codes, time code
and recording date jumps, repeated/dropped/truncated frames, and missing aux data.
**118 of 120 damaged files give a byte-identical XML report.** The 2 differences are
deliberate. MediaInfoLib reads the recording date/time of the subcode area at the wrong
byte offsets, so DVRescue misses that date when the video aux data is damaged. OldDV
Rescue reads it correctly. To re-run the comparison:
`tests/compare_with_dvrescue.sh /path/to/dvrescue build/olddv /tmp/work file.dv`.

The merge works differently from DVRescue's, so it is not byte-identical, but it follows
the same principle of best frame plus block replacement. On the test sets it recovered
the complete timeline where DVRescue's merge lost frames.

`tests/run_tests.sh` runs a quick self test. It needs ffmpeg and python3.

## How the prebuilt app is made

`tools/cross-build.sh` compiles everything on Linux with clang against the real Mac OS X
10.6 SDK, and links with `ld64.lld`. Every symbol the app imports is resolved against the
10.6 SDK libraries, so it only calls APIs that exist on Snow Leopard. Modern linkers only
write the 10.8+ `LC_MAIN` entry point, so a small start-up routine
(`tools/crt_start_10_6.c`) is linked in and `tools/macho_unixthread.py` converts the entry
point to the classic `LC_UNIXTHREAD` form that 10.6 understands. The AVFoundation engine
is compiled against a newer SDK but loaded with `dlopen` only on 10.7+, so nothing in the
binary requires it on 10.6.

**Important:** the prebuilt app has not been run on a real Mac or with a real camcorder.
It was built and checked on Linux. If it does not start, or capture shows no frames,
build it yourself with `./build.sh` (Option B). If you still have problems, the
messages in the Capture log, or in Console.app, say what went wrong.

## Layout

```
src/core/      portable C: DV analysis (dvanalyze.c), XML/CSV report (dvreport.c),
               merge (dvmerge.c), packager (dvsplit.c)
src/cli/       olddv command line tool
src/mac/       Cocoa app: OVApp (window), OVEngine (capture + retries), OVCapture
               (QTKit / AVFoundation), OVDeck (AV/C control), OVViews (graph, block map)
tests/         damage injector, comparison with DVRescue, self test
tools/         cross build, icon
dist/          prebuilt app (zip)
```

## Credits and licence

See [NOTICE.md](NOTICE.md). The analysis rules and the report format come from DVRescue
(© MIPoPS, BSD-3-Clause) and MediaInfoLib (© MediaArea.net SARL, BSD-2-Clause). This
project is an independent re-implementation, made for personal use.
