# Record with a Mac microphone

Connect BMonitor to Blackmagic Camera and open the **Audio** popover. Choose the built-in Mac microphone or a connected microphone under **Monitor microphone**. Allow microphone access when macOS prompts. The meter follows the selected input even with **Listen on Mac** turned off. Expand **iPhone audio** to adjust the audio Blackmagic Camera uses.

Selecting a Mac microphone enables a local copy for each take. Start and stop recording from BMonitor or Blackmagic Camera as usual. Use **Camera → Show Copies in Finder** or the existing copy controls to locate the files. Select **iPhone** to return to the original monitoring and copy settings.

| Mac recording setting | Files |
| --- | --- |
| Replace iPhone audio | A video MOV with the Mac microphone as its audio track |
| Save Mac mic to a separate file | The usual video MOV plus an audio-only `- Mac Mic.mov` with the same timeline origin |
| Keep two audio tracks in the video | One MOV with independent iPhone and Mac audio tracks |

The Mac recording uses the compressed HEVC video from the SRT live stream. Resolution and bitrate depend on the stream. Blackmagic Camera continues saving its own original clip to the iPhone with the phone's audio settings.

## Check audio and video sync

1. Use the packaged macOS app so that the microphone privacy prompt is available. Connect the iPhone and select the built-in Mac microphone. Check that speaking moves the live meter.
2. In **Replace iPhone audio** mode, leave **Microphone delay** at 300 ms for the first take. Record a visible clap close to the Mac microphone.
3. Open the local MOV in an editor with frame stepping and an audio waveform. Compare the frame where the hands touch with the start of the clap waveform. If audio is 80 ms early, add 80 ms to **Microphone delay**. If audio is 80 ms late, subtract 80 ms. Record again to verify. Recheck after changing the connection or SRT buffering.
4. Record a longer take with claps at the beginning and end. Compare each waveform against its corresponding video frame to check for drift. Repeat with a USB microphone and each recording mode. For the separate file, place both clips at timeline zero. For the two-track MOV, solo each track in an editor.
5. Check access and disconnect handling. Deny permission and confirm iPhone audio remains selected. Re-enable access in **System Settings → Privacy & Security → Microphone**. Unplug the selected USB microphone during a take. Check the meter and the saved-copy warning, then reconnect and reselect the microphone for another take.
6. Play the iPhone's original file and confirm it still uses the audio set in Blackmagic Camera.

## Timing model

AVFoundation converts microphone sample timestamps onto the Mac host clock. The recorder observes incoming SRT video PTS against the same clock. It uses the earliest arrivals in successive windows to estimate the relative rate while reducing the effect of network jitter. The microphone delay adds a user-calibrated constant to this mapping. The default 300 ms is based on the project's measured live-stream delay. The SRT stream supplies no shared capture clock with the Mac, so a one-way latency change can still affect alignment.

The recorder keeps its keyframe pre-roll and stop tail. It assigns the Mac samples to the video timeline and encodes them as AAC. In separate-file mode both writers start at the same video PTS. In two-track mode the phone AAC and Mac AAC remain independently editable. Selecting a microphone starts capture for metering, and a recording event controls when samples are written to disk.
