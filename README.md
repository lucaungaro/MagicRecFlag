<p align="center">
  <img src="logo/Magic Rec Flag.png" width="140" alt="Magic Rec Flag">
</p>

<h1 align="center">Magic Rec Flag</h1>

**Magic Rec Flag** watches a corner of a video feed for a red *recording* tally light and, the moment it lights up, presses your **Record** shortcut in another application for you — then presses **Stop** when the light goes out. It was built to keep a recorder such as **QTake** in sync with a camera's tally signal, hands‑free.

## How it works

You point Magic Rec Flag at a video capture device, draw a small rectangle over the part of the picture where the red tally appears, and tell it which app to control and which keyboard shortcuts to send.

From then on:

1. It continuously analyses the pixels inside your rectangle.
2. When enough **red** appears — and stays for a few frames — it sends your **Record** shortcut to the target app.
3. When the red goes away, it sends your **Stop** shortcut.
4. A small always‑on‑top badge shows the current state — **STBY** or **REC** — with a Stop button, so you always know what it is doing.

Detection works in HSV colour space (hue / saturation / brightness), so it locks onto a genuine red light and ignores greys, whites and shadows. A sensitivity slider lets you tune how much red counts as "on."

## Setting it up

On first launch a short wizard walks you through everything, and your choices are remembered for next time:

1. **Capture device** — pick your video input.
2. **Detection region** — drag a rectangle over the live preview, on top of where the tally light shows.
3. **Target application** — choose the app that should start and stop recording.
4. **Keyboard shortcuts** — set the Record and Stop shortcuts to match the target app's.
5. **Ready** — review and launch live mode.

## Requirements

- **macOS 13 (Ventura) or later** — Apple Silicon or Intel.
- A **video capture device**, either:
  - a **Blackmagic DeckLink / UltraStudio** device — captured natively, and requires [**Blackmagic Desktop Video**](https://www.blackmagicdesign.com/support/family/capture-and-playback) to be installed; or
  - any **AVFoundation** camera or virtual camera (a webcam, NDI Virtual Input, etc.).
- **Accessibility permission** — so the app can send keystrokes to the target application.
- **Camera permission** — requested on first launch.

## Installing

1. Download the latest **`Magic Rec Flag.zip`** from the [**Releases**](https://github.com/lucaungaro/MagicRecFlag/releases) page.
2. Unzip it and drag **Magic Rec Flag.app** into your **Applications** folder.
3. The app is signed to run locally but is **not notarized**, so macOS blocks it on first open. Clear the quarantine flag once, in Terminal:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Magic Rec Flag.app"
   ```
   (Or: right‑click the app → **Open**, then confirm **Open** in the dialog.)
4. Launch it and grant the two permissions it needs:
   - **Camera** — approve the prompt.
   - **Accessibility** — open **System Settings → Privacy & Security → Accessibility** and switch **Magic Rec Flag** on. Without this, the app can see the tally but cannot send the Record/Stop shortcuts.

## Tips

- Getting **false triggers**? Raise the red‑threshold slider in the Detection Region step.
- Keep the detection rectangle **tight** around the tally light for the most reliable results.
- Make sure the target app's Record/Stop hotkeys match what you set here, and that it responds to them while running in the background.

## License

See [LICENSE](LICENSE).
