# VoiceSidecar

Local macOS menu-bar app that records WAV audio while holding Fn and lets you review transcripts before exporting a dataset.

## M1 build

GitHub Actions builds an arm64 app with a macOS 13.0 deployment target. Open Actions, select a successful **Build VoiceSidecar for M1** run, and download **VoiceSidecar-M1**. Extract the artifact, then extract `VoiceSidecar-M1.zip` to get `VoiceSidecar.app`.

For an approved local build with compatible Xcode tools: `ARCH=arm64 bash build.sh`. Output: `dist/VoiceSidecar.app`.

The app has an ad-hoc signature, not Developer ID signing or Apple notarization. On a company Mac, installation and Microphone, Input Monitoring, and Accessibility permissions require company policy approval. Ask IT if macOS or device management blocks the app. Do not bypass those controls. GitHub Actions does not change permissions on your Mac.

Only application source is stored here. Recordings and transcripts remain on your Mac unless you explicitly share them. Runtime behavior and Fn detection must be tested on an approved physical Mac after permissions are granted.
