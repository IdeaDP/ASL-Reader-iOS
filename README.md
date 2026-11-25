# ASL Reader for iOS

ASL Reader is an iPhone app for live American Sign Language fingerspelling. It uses the fine-tuned RapidNet-Ti Core ML model and Apple's Vision and AVFoundation frameworks to recognize one handshape at a time, then builds text from the recognized signs.

This is a fingerspelling reader, not a full ASL sentence translator. It recognizes static handshapes; it does not interpret sign motion, grammar, or continuous words as a person signs.

## Features

- Live camera preview with on-device sign predictions.
- Switch between the front and rear cameras.
- Choose **A–Z**, **0–9**, or **Both**. Selecting letters or digits filters ambiguous labels such as `O`/`0`, `V`/`2`, and `W`/`6`.
- See the current prediction, confidence, hold progress, and three highest-scoring predictions.
- Type a sign after holding it steadily, then compose the symbols into a text area.
- Use **Space**, **Delete**, **Clear**, and **Pause/Read** controls to edit or pause recognition.
- See up to three spelling suggestions for the current word.
- Speak the current word or the completed text with the iPhone's English speech voice.
- Adjust confidence, hold duration, automatic spacing, word-speech, and left-handed input in **Settings**.
- View live model latency and processed frame rate.

## Using the app

1. Launch the app and allow camera access.
2. Hold one hand in the dashed square in the camera preview. The model evaluates the central 90% of the square image.
3. Choose **A–Z**, **0–9**, or **Both** below the preview.
4. Hold a clear sign until the progress ring completes. The recognized symbol is added to the text area.
5. Lower your hand between repeated copies of the same sign, or hold the same sign longer. Use **Space**, **Delete**, or **Clear** to edit the result.
6. Tap a word suggestion to accept it. Use **Speak** to read the text aloud.

### Settings

| Setting | Default | Available values / purpose |
|---|---:|---|
| Confidence threshold | 70% | 40–95%; a prediction below this is treated as no clear sign. |
| Hold time | 0.8 s | 0.3–2.0 s; how long a sign must remain confident before it is typed. |
| Auto-space after a pause | On | Adds a space after the hand has no confident sign for the selected pause length. |
| Pause length | 2.0 s | 1.0–4.0 s; shown when automatic spacing is enabled. |
| Left-handed signer | Off | Mirrors model input for left-handed use. The model was trained on right-handed signs. |
| Speak each finished word | On | Uses text-to-speech when a word is completed by a space or automatic pause. |

To type the same sign twice without lowering your hand, hold the second sign for about twice the configured hold time.

## Recognition model and limitations

The app expects `ASLReader/ASLRapidNet.mlmodel`, a RapidNet-Ti model with 36 labels: the digits `0–9` and lowercase letters `a–z`. Core ML is configured to use available compute units, including the Neural Engine when supported by the device.

For best results, use one clearly visible hand, good lighting, and a plain dark background. The training images used right-handed signs. The left-handed option mirrors the image sent to the model, but recognition quality can still vary with signer, lighting, camera angle, and background.

The model classifies individual frames. Motion-based signs such as `J` and `Z` cannot be fully recognized as movements; the app can only classify a still handshape. Recognition is intended for fingerspelling and does not translate ASL grammar or full sentences.

## Build and run

### Build locally on a Mac

Requirements: macOS with Xcode, and XcodeGen.

```sh
brew install xcodegen
xcodegen generate
open ASLReader.xcodeproj
```

In Xcode, choose an iPhone target, select your signing team, and run the **ASLReader** scheme. The project targets iOS 16 and later. The generated Xcode project is based on `project.yml`.

### Build from Windows with GitHub Actions

The repository includes a GitHub Actions workflow that builds on a GitHub-hosted macOS runner. A push to `main` or `master` starts it automatically; it can also be started from **Actions → Build ASL Reader IPA → Run workflow**.

The workflow needs the real Core ML model file at `ASLReader/ASLRapidNet.mlmodel`. If the model is missing or the file contains only a Git LFS pointer, the build stops with an error.

After a successful run, download the **ASLReader-IPA** artifact from that workflow run and extract `ASLReader.ipa` from the downloaded archive. The workflow builds with code signing disabled, so the IPA must be signed for your Apple Account before installing it. On Windows, AltServer and AltStore can sign and install the IPA to a connected iPhone. With a free Apple Account, refresh the app through AltStore within seven days.

## Privacy

The camera feed is processed by the on-device Core ML/Vision model. The app source has no remote inference server or networking feature. Camera access is required for recognition and can be changed in iOS Settings.

## Project files

- `ASLReader/` — SwiftUI interface, camera capture, recognition logic, app settings, assets, and the Core ML model.
- `project.yml` — XcodeGen project configuration.
- `.github/workflows/build.yml` — GitHub Actions build and unsigned IPA packaging workflow.

## References

- [ASL-Reader-iOS source repository](https://github.com/IdeaDP/ASL-Reader-iOS)
- [RapidNet official repository](https://github.com/mmunir127/RapidNet-Official)
- [RapidNet paper](https://openaccess.thecvf.com/content/WACV2025/papers/Munir_RapidNet_Multi-Level_Dilated_Convolution_Based_Mobile_Backbone_WACV_2025_paper.pdf)
