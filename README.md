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
| `dvpackager` (split at each recording, rewrap to .mov) | **Package & Export** tab: one file per recording. Lossless `.mov` (DV + PCM) is built in; H.264 `.mp4` / `.mov` need ffmpeg. |
| `dvloupe` / `dvplay` (block error map of a frame) | **Analyze** tab: error timeline, list of bad frames, block map and picture of each frame |

Not included: DeckLink/analog capture, closed caption export (SCC/SRT/WebVTT), MKV output,
and DVRescue's Qt player/GUI.

## Install

### Option A: prebuilt app

1. Copy `dist/OldDV-Rescue-1.1.0-mac.zip` to the Mac and double-click it.
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
     recorded part of the tape. A camcorder that has stopped keeps sending frames (a
     frozen or blank picture), so the app looks at the frames, not only at the data
     flow: it finishes when there has been no moving, readable picture for N seconds and
     the deck reports that it has stopped. While the deck still plays (a blank section
     between two recordings), it waits 6 × N seconds, at least 90.
   * *Re-read sections with errors: N times*: after the first pass, the deck rewinds to each
     section that had errors (located by time code), plays it again and records it into
     `name.retry1.dv`, `name.retry2.dv`, and so on. All takes are then merged into
     `name.merged.dv`, keeping the best blocks of every take. This is DVRescue's
     "rewind count", run as a pass after the capture. It needs deck control and a tape with
     time code, which consumer DV always has. If more than 30 % of the frames have errors,
     the retry is skipped: capture the whole tape a second time and use *Merge Takes*.
     **The section retry has not been validated on real hardware yet; leave it at 0 for
     tapes that matter.**
4. **Start Capture**. The graph shows errors as they happen. Red bars mean concealed video
   blocks, orange bars mean audio errors, blue marks show a new recording on the tape, and
   yellow marks show a time code break.

Each `.dv` file gets a `.dv.dvrescue.xml` report next to it, and the Capture log is saved
as `name.log` in the same folder (and always in `~/Library/Logs/OldDV Rescue.log`).
The log gets a progress line every 5 minutes and a line when a blank section starts or
ends. While the tape is blank, the status shows `REC, blank 130/360 s`: the seconds without
a picture, and the limit at which the capture finishes by itself if the deck keeps playing.

If the app or the Mac dies during a capture, the `.dv` is still good up to the last data
written. Only the XML report is missing: open the file in the *Analyze* tab, or run
`olddv name.dv -x name.dv.dvrescue.xml`.

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
The **first** capture is the timeline: the merged file has its frames, in its order. The
frames of the other captures are attached to it by following the sequence, and located
by absolute track number and time code after a jump. Neither is unique on a real tape
(time code restarts after a blank section, and some camcorders restart the track number
at every recording), so they are never used to sort frames. One-off glitches are ignored.
Frames found only in a later capture are inserted where they belong. For each frame, the
take with the fewest bad blocks is used, and each of its bad blocks is replaced by a good
copy of the same block from another take.

### Package & Export

Splits a capture into one file per recording (optionally also at 4:3/16:9 or audio
changes and at time code breaks), and/or converts it. Untick **Split** to convert the
whole file.

| Format | What it is | Size | Needs |
|---|---|---|---|
| `.dv` | raw DV, your archival master | 13 GB/h | built in |
| `.mov` (DV) | the same DV video, untouched, plus PCM audio in a QuickTime file. Lossless. Plays in QuickTime 7/X, iMovie, Final Cut, VLC. | 13 GB/h | built in |
| `.mp4` (H.264) | H.264 video + AAC audio, for sharing, phones, Plex/Jellyfin | ~1–1.5 GB/h | ffmpeg |
| `.mov` (H.264) | the same, in a QuickTime file | ~1–1.5 GB/h | ffmpeg |

H.264 options:
* **Quality:** CRF 18 / 20 / 23 / 26 (lower is better and bigger).
* **Deinterlace:** on by default. DV is interlaced and computers show combing without it.
* **Square pixels:** on by default. Gives 640×480 / 854×480 for NTSC, 768×576 / 1024×576
  for PAL. Untick it to keep 720×480 with the aspect ratio flag.

The Capture tab can convert automatically when a capture ends: use **Then create:**
`.mov (DV)`, `.mp4`, or both.

**Where the encoder comes from.** The app looks, in this order, for:
1. the path typed in the *Encoder* field;
2. an `ffmpeg` inside the app (`OldDV Rescue.app/Contents/Resources/ffmpeg`);
3. MacPorts (`/opt/local/bin/ffmpeg`), then `/usr/local/bin/ffmpeg`.

MacPorts still supports Snow Leopard. Installing ffmpeg with it takes a few hours to
compile on a Core 2 Duo, but it is the official way to get it:

```bash
sudo port install ffmpeg +gpl2
```

**Audio repair.** When a deck cannot read an audio block it sends an error code instead
of the samples. This is common with tapes recorded on another camcorder or in LP mode,
and with a dirty head: the picture is fine but a third of the audio samples are missing,
on every other track. Players (and ffmpeg) play the holes as silence, which sounds like
a loud buzz over the whole recording. DV spreads the samples of a frame over its tracks
precisely so that such holes are short, so the exports fill them by interpolation between
the good neighbours (holes longer than 1 ms are muted with a fade). This applies to the
`.mov` (DV) audio track and to the H.264 exports; the `.dv` file and the DV video are
never changed. The log says how much was repaired. On the command line:
`olddv tape.dv --wav audio.wav` writes the repaired audio alone, and
`--no-audio-repair` gives the old behaviour.

The lossless `.mov` was checked with ffmpeg: the DV frames inside are bit-identical to the
`.dv`, and the audio matches ffmpeg's own DV audio decoding sample for sample. That
covers 16-bit 48 kHz, 12-bit 32 kHz 4-channel, NTSC and PAL.

## Saving to an Unraid (or other NAS) share

Snow Leopard can't talk to a modern Samba/Unraid share: it only knows SMB1, which Unraid
turns off by default. Three ways around it, best first:

**1. NFS (recommended).** Mac OS X 10.6 has a built-in NFS client, and Unraid has an NFS server.
* On Unraid:
  1. *Settings → NFS*: set *Enable NFS* to **Yes**.
  2. *Shares → (your share) → NFS Security Settings*: set *Export* to **Yes**.
  3. Set *Security* to **Public**, or **Private** with the rule
     `192.168.1.50(sec=sys,rw,insecure)`, using your Mac's IP address.
* On the Mac:
  1. In Finder, choose *Go → Connect to Server…* (⌘K).
  2. Enter `nfs://tower.local/mnt/user/YourShare`, using your server's name or IP. The
     share appears under `/Volumes/YourShare`.
  3. In OldDV Rescue, set *Save to* to that folder.
* To mount it automatically at every start-up: open *Disk Utility → File → NFS Mounts…*,
  click **+**, enter `nfs://tower.local/mnt/user/YourShare`, and set the mount location
  to `/Volumes/YourShare`.
* If the mount fails with a permission error, mount it from Terminal using a privileged
  port:

  ```bash
  sudo mkdir -p /Volumes/YourShare
  ```

  ```bash
  sudo mount -t nfs -o resvport,rw tower.local:/mnt/user/YourShare /Volumes/YourShare
  ```

**2. SMB1.** Unraid 6 can turn on SMB1 for old clients: *Settings → SMB → Enable NetBIOS:
Yes*. Then use *Go → Connect to Server* with `smb://tower.local/YourShare`. It works, but
SMB1 is slow and insecure, so use it only on your home network. Newer Unraid versions may
no longer offer this option; use NFS then.

**What OldDV Rescue does to make network capture safe.** When the folder you chose is on a
network share, the capture is recorded on the internal disk first, in
`~/Movies/OldDV Rescue Cache`, and copied to the share in the background while the tape
plays. A share that stalls or disconnects can't hurt the capture:

- The Capture tab shows *To copy: …*, the amount not yet on the share. It shows
  *SHARE DOWN, safe here: …* while the share doesn't answer. The copy continues by itself
  when the share is back.
- When the capture ends, the rest is copied and every file is compared with the recording.
  Only then is the recording on the Mac removed. The button reads *Stop Copy* during this
  step; a 60 minute tape takes a few minutes to compare.
- If the share is still gone, or you stop the copy, the capture stays in the cache folder
  and the log says so. The app lists such captures when it starts. Copy them by hand, or
  with `olddv name.dv --copy-to /Volumes/Share/name.dv` (waits for the share, retries, and
  compares).
- The Mac needs 15 GB free. With less, the app asks whether to record straight to the
  share. Then only a 256 MB memory buffer (about 70 seconds) protects the capture, and the
  rest of the tape is lost if the share stays away longer.

Folders on internal, USB and FireWire disks are recorded to directly, as before.

Wired gigabit Ethernet is plenty, since DV needs only 3.6 MB/s. Wi-Fi works but is less
reliable.

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

```bash
olddv tape.dv --mov tape.mov
```

* `-s`: print a summary.
* `-x`: write the XML report (DVRescue format).
* `-m`: merge takes, picking the best blocks of each.
* `--split`: write one file per recording.
* `--mov`: lossless QuickTime rewrap (audio error codes repaired).
* `--wav`: the repaired audio as a `.wav` file.

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

The same script runs on a modern Mac with Homebrew `llvm` and `lld` in the `PATH` and the
10.6 / 10.11 SDKs unpacked somewhere (`SDK106=... SDK_AVF=... tools/cross-build.sh`).

**Important:** the raw capture path has been confirmed on a late-2009 Mac mini with a PAL
camcorder (a clean DIF stream of whole frames over a one hour capture). Deck control,
the end-of-tape detection and the section retry have not been validated on hardware yet. If it does not start, or capture shows no frames,
build it yourself with `./build.sh` (Option B). If you still have problems, the
messages in the Capture log, or in Console.app, say what went wrong.

## Layout

```
src/core/      portable C: DV analysis (dvanalyze.c), XML/CSV report (dvreport.c),
               merge (dvmerge.c), packager (dvsplit.c), lossless .mov writer (dvmov.c),
               buffered writer for slow/network disks (dvwriter.c)
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
