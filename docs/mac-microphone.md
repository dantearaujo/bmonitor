# Record with a Mac microphone

The image comes from the iPhone; the sound comes from the Mac's built-in microphone or any microphone connected to the Mac. bmonitor puts them in one file, already in sync, so the take needs no editing.

## Choose the microphone

Connect bmonitor to Blackmagic Camera and open the **Audio** popover. Choose the Mac input under **Monitor microphone** and allow microphone access when macOS asks. The meter follows the selected input. **Keep an audio source on in the iPhone**: its sound is the reference bmonitor uses to sync the Mac audio, and is not what ends up playing.

Selecting a Mac microphone turns on the Mac copy of each take. Start and stop recording from bmonitor or Blackmagic Camera as usual.

## What each take produces

When a take stops, bmonitor writes, in the copies folder:

| File | Contents |
| --- | --- |
| `<clip> bmonitor.mov` | The stream image (camera resolution, 8 Mb/s) with the Mac audio, synced |
| `<clip> bmonitor - Mac Mic.mov` | The Mac microphone alone, 48 kHz 24-bit PCM, kept for the original merge below |

The **Recording on the Mac** setting chooses what happens to the iPhone audio in the merged file:

| Setting | Merged file |
| --- | --- |
| Replace iPhone audio | Image + Mac audio only |
| Keep two audio tracks in the video | Image + Mac audio (playing) + iPhone audio (disabled, available to the editor) |
| Save Mac mic to a separate file | No merge: image with iPhone audio, plus the Mac audio file |

## Full-quality original

Blackmagic Camera keeps the original clip (full resolution and bitrate) on the iPhone, and its API does not let it be downloaded over the network. Copy it to the Mac (AirDrop, cable, Files), then choose **Camera → Merge iPhone Original with Mac Audio…** and select one or more clips. bmonitor finds the Mac audio of each take by the clip name (`A001_11210140_C001.mov` → `A001_11210140_C001 bmonitor - Mac Mic.mov` in the copies folder), aligns it and writes `A001_11210140_C001 Mac.mov` next to it. The image, timecode and other tracks are copied as they are, without re-encoding. If the Mac audio file is not found, bmonitor asks for it.

## How the sync works

1. While recording, AVFoundation stamps each microphone sample with the Mac host clock, and `MicrophoneSync` maps that clock onto the stream's video timestamps (correcting the slow drift between the two clocks). **Microphone delay** adds a constant on top; it now only sets the starting guess.
2. When the take closes, `AudioAlignment` compares the Mac audio with the iPhone audio recorded in the same take (GCC-PHAT cross-correlation at 8 kHz, voice band, first 120 s) and finds the exact offset. Both microphones hear the same room, so the peak is sharp even with different mics. In the stream copy the search is ±1 s around the guess; for the original clip, any offset.
3. `MacAudioMerger` copies the video samples into the new file and inserts the Mac audio at that offset.

If the comparison is not conclusive (the iPhone audio was off, or silence), the stream copy keeps the clock-based position and shows a warning; the original merge stops with an error instead of guessing.

## Checking sync

Record a clap in front of the camera. In an editor with frame stepping and waveforms, the frame where the hands touch should line up with the start of the clap within one frame. Running the app binary from a terminal prints the offset found for each take: `cópia no Mac: microfone em +0.120 s, confiança 51.5`.
