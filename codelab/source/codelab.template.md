summary: Build a Flutter app that runs Gemma 4 on the device: streaming chat, image understanding, visible reasoning and function calling, with no server and no API key.
id: flutter-gemma-on-device
categories: Flutter, AI, Gemma
environments: Web
status: Published
feedback link: https://github.com/jakansha2001/gemma-on-device-demo/issues
authors: Akansha Jain

# Building On-Device AI Apps with Flutter and Gemma

## Overview
Duration: 0:04:00

In this codelab you build a Flutter app that runs **Gemma 4 E2B**, Google's open model, entirely on the device. Once the model is downloaded, every token is generated on the phone or laptop in your hand. Nothing is sent to a server, there is no API key, and the app keeps working in airplane mode.

The app uses [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai), a Flutter plugin that loads `.litertlm` models through Google's LiteRT-LM runtime.

### What you'll build

A small app with four on-device features:

* **Chat** with replies that stream in token by token.
* **Vision**: attach a photo and ask questions about it.
* **Thinking**: watch the model reason through a problem before it answers.
* **Tools**: the model calls Dart functions in your app. It adds tasks to a to-do list and recolors the app bar.

### What you'll learn

* How flutter_edge_ai splits a small core from opt-in engine packages
* How to download a 2.6 GB model once, with progress, and load it onto the GPU
* How to stream text, send images, show reasoning tokens, and run a function-calling loop
* The platform setup Android, iOS and macOS each need
* The mistakes that cost the most time when building this, so you can skip them

### What you'll need

* Flutter **3.44 or newer** (flutter_edge_ai needs Dart 3.12+)
* An IDE such as VS Code or Android Studio
* About **3 GB of free space on the test device** for the model, and a fast connection for the first download
* One of:
  * A physical **Android** phone with an arm64 CPU, running **Android 11 (API 30) or newer**. Recent, high-memory phones work best.
  * A physical **iPhone** and a Mac with Xcode
  * An **Apple Silicon Mac**, to run the app as a macOS desktop app

> aside negative
> The model is loaded entirely into memory. On phones with little RAM the operating system can kill the app while the model loads. If that happens, try a device with more memory.

## How the pieces fit together
Duration: 0:05:00

Three things about this stack explain why the code below looks the way it does.

### The package is modular

`flutter_edge_ai` is a **core** package: model management, chat sessions and the response types. It ships without an inference engine. You add the engine you need and register it at startup:

| Package | What it adds |
|---|---|
| `flutter_edge_ai_litertlm` | Runs `.litertlm` models through LiteRT-LM. Used in this codelab. |
| `flutter_edge_ai_mediapipe` | Runs older `.task` / `.bin` models through MediaPipe |
| `flutter_edge_ai_speech` | On-device speech-to-text and text-to-speech |
| `flutter_edge_ai_sqlite`, `flutter_edge_ai_qdrant` | Vector stores for on-device RAG |
| `flutter_edge_ai_agent` | Skills the model can run through function calling |

Your app only bundles the native libraries for the packages you add.

> aside positive
> **Searching and finding `flutter_gemma`?** That's this package under its old name. Posts and answers written for it still apply; the class is `FlutterEdgeAi` now, and `dart fix --apply` renames the old symbols for you.

### Gemma 4 E2B, no token required

This codelab uses [Gemma 4 E2B in LiteRT-LM format](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) from the `litert-community` organization on Hugging Face. The download is public, so there is **no Hugging Face account, access request or token** to manage. The "E" in E2B stands for *effective* parameters. Gemma 4 is released under the Apache 2.0 license.

Gemma 4 E2B accepts text and images, can stream its reasoning, and supports function calling natively, and you use all of these below.

### One chat call covers everything

A single `InferenceChat` streams a sealed `ModelResponse` type: `TextResponse`, `ThinkingResponse`, `FunctionCallResponse` and `ParallelFunctionCallResponse`. Because the type is sealed, a Dart `switch` over it is checked for exhaustiveness at compile time.

## Set up your environment
Duration: 0:05:00

### Check your Flutter version

```bash
flutter --version
```

You need Flutter **3.44.0 or newer**. That's what flutter_edge_ai declares, together with Dart 3.12. The packages use Dart build hooks (Native Assets) to download and bundle the LiteRT-LM native libraries when you build.

If you're on an older version, upgrade:

```bash
flutter upgrade
```

> aside positive
> **Can't upgrade your global Flutter?** Use [FVM](https://fvm.app) to pin a newer Flutter for this one project and leave your other projects alone: `fvm use stable` inside the project folder, then prefix commands with `fvm`, for example `fvm flutter run`.

### Check your device

```bash
flutter devices
```

Make sure your phone or Mac appears in the list.

> aside negative
> The `.litertlm` engine on Android ships **arm64-v8a** libraries only. x86 and x86_64 Android emulators can't load it. Use a physical arm64 phone. On an Apple Silicon Mac, the Android emulator runs arm64 images natively.

## Create the project and add packages
Duration: 0:04:00

Create a new Flutter project for Android, iOS and macOS:

```bash
flutter create --platforms=android,ios,macos gemma_codelab
cd gemma_codelab
```

Add the three packages this app needs:

```bash
flutter pub add flutter_edge_ai flutter_edge_ai_litertlm image_picker
```

Your `pubspec.yaml` dependencies now look like this (patch versions may be newer):

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  flutter_edge_ai: ^2.1.1
  flutter_edge_ai_litertlm: ^1.10.1
  image_picker: ^1.2.3
```

| Package | Why |
|---|---|
| `flutter_edge_ai` | Model download, chat sessions, response types |
| `flutter_edge_ai_litertlm` | The engine that runs `.litertlm` models on the GPU |
| `image_picker` | Choosing a photo for the vision step |

Delete the default widget test. It refers to the counter app you're about to replace:

```bash
rm test/widget_test.dart
```

## Configure Android
Duration: 0:05:00

Skip this step if you're not targeting Android.

### Set the minimum SDK and restrict the build to arm64

`.litertlm` inference needs **API 30**, and the engine only ships arm64 libraries. Setting both here means an unsupported device can't install the app and then crash when the engine starts.

Open `android/app/build.gradle.kts` and edit `defaultConfig`:

```kotlin
defaultConfig {
    // ...keep the generated values (applicationId, targetSdk, and so on)...
    minSdk = 30
    ndk { abiFilters += listOf("arm64-v8a") }
}
```

### Update the manifest

Replace `android/app/src/main/AndroidManifest.xml` with the version below. It's the default Flutter manifest, without the generated comments, plus three additions:

1. **`INTERNET`** in the main manifest. Flutter only adds it to debug builds by default, and a release build needs it to download the model.
2. **Foreground download permissions.** The model downloads with `foreground: true`, which shows a progress notification and keeps a long download running.
3. **The `SystemForegroundService` override.** On Android 14+ (API 34), a foreground download crashes without `foregroundServiceType="dataSync"`. flutter_edge_ai leaves this to the app on purpose because `FOREGROUND_SERVICE_DATA_SYNC` is a Play-sensitive permission.

The GPU entries that let the engine load the vendor's OpenCL driver come from the package's own manifest and are merged in for you, so there is nothing to add for them.

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />

    <application
        android:label="gemma_codelab"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:taskAffinity=""
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data
              android:name="io.flutter.embedding.android.NormalTheme"
              android:resource="@style/NormalTheme"
              />
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />

        <!-- Android 14+: foreground model download -->
        <service
            android:name="androidx.work.impl.foreground.SystemForegroundService"
            android:foregroundServiceType="dataSync"
            tools:node="merge" />

    </application>
    <queries>
        <intent>
            <action android:name="android.intent.action.PROCESS_TEXT"/>
            <data android:mimeType="text/plain"/>
        </intent>
    </queries>
</manifest>
```

> aside positive
> `image_picker` needs no extra Android permissions. It opens the system camera or photo picker, which handle access themselves.

## Configure iOS
Duration: 0:04:00

Skip this step if you're not targeting iOS.

### Deployment target

flutter_edge_ai needs **iOS 15.0** or later. Projects created with Flutter 3.47 already target 15.0. To check, open `ios/Runner.xcworkspace` in Xcode, select the **Runner** target, and look at **Minimum Deployments**.

> aside positive
> New Flutter projects use Swift Package Manager and have no `Podfile`. flutter_edge_ai works without one on iOS. Set the deployment target on the Runner target, as above.

### Info.plist

Open `ios/Runner/Info.plist` and add these keys inside the top-level `dict` element. The camera and photo library descriptions are required by `image_picker`. `UIFileSharingEnabled` is part of flutter_edge_ai's iOS setup.

```xml
<key>NSCameraUsageDescription</key>
<string>Take a photo to ask Gemma about it. The photo stays on this device.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Choose a photo to ask Gemma about it. The photo stays on this device.</string>
<key>UIFileSharingEnabled</key>
<true/>
```

### Memory entitlements

iOS limits how much memory an app can use, and a 2.6 GB model gets close to that limit. In Xcode, select **Runner → Signing & Capabilities → + Capability** and add **Increased Memory Limit** and **Extended Virtual Addressing**. Xcode creates `ios/Runner/Runner.entitlements` for you:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
</dict>
</plist>
```

> aside negative
> These are iOS entitlements only. Don't add them to the macOS entitlement files: Xcode would then require a development signing certificate for your macOS build.

## Configure macOS
Duration: 0:06:00

Skip this step if you're not targeting macOS.

### Entitlements

macOS apps run in a sandbox. Add these keys to **both** `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`, inside the `dict` element:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

| Key | Why |
|---|---|
| `network.client` | Outbound connections, for the one-time model download |
| `cs.disable-library-validation` | Lets the app load the LiteRT-LM GPU libraries that flutter_edge_ai copies into the bundle |
| `files.user-selected.read-only` | Lets `image_picker` open a photo you choose |

### Stage the GPU libraries into the app

On macOS, LiteRT-LM depends on two companion libraries (`libGemmaModelConstraintProvider.dylib` and `libLiteRtLmMetalAccelerator.dylib`) that the build hook can't bundle automatically. `flutter_edge_ai_litertlm` ships a script that copies them into your `.app` and fixes the engine's reference to them, and your build has to run it.

> aside negative
> Without this step the app still builds. It fails at the first model load, with `Library not loaded: @rpath/libGemmaModelConstraintProvider.dylib`. A successful build does not tell you this step worked.

The script runs from an Xcode build phase, which CocoaPods adds for you. Turn off Swift Package Manager for the app so that `macos/Podfile` is generated. Add this to `pubspec.yaml`:

```yaml
flutter:
  uses-material-design: true
  config:
    enable-swift-package-manager: false
```

Then regenerate the macOS project files:

```bash
flutter pub get
```

Open `macos/Podfile` and replace its `post_install` block with this one:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)
  end

  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.user_targets.each do |user_target|
      phase_name = '[flutter_gemma] Setup LiteRT-LM macOS'

      # Only the app target has a Contents/Frameworks to patch. On any other
      # target the phase creates an Xcode dependency cycle, so drop it there.
      unless user_target.name == 'Runner'
        user_target.build_phases
          .select { |p| p.respond_to?(:name) && p.name == phase_name }
          .each { |p| user_target.build_phases.delete(p) }
        next
      end

      existing = user_target.shell_script_build_phases.find { |p| p.name == phase_name }
      phase = existing || user_target.new_shell_script_build_phase(phase_name)
      # Flutter re-copies the raw engine binary on every build. Declaring it as
      # an input makes this phase run again afterwards, so the app never ships
      # an unpatched engine.
      phase.input_paths = [
        '$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm',
      ]
      phase.output_paths = ['$(DERIVED_FILE_DIR)/flutter_gemma_litertlm_macos.stamp']
      phase.shell_script = <<~SHELL
        set -e
        STAGER="${HOME}/Library/Caches/flutter_gemma/native/macos_arm64/stage_macos_companions.sh"
        if [ ! -f "${STAGER}" ]; then
          echo "ERROR: ${STAGER} not found. Run: flutter clean && flutter pub get" >&2
          exit 1
        fi
        sh "${STAGER}" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Frameworks"
        mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
        touch "${SCRIPT_OUTPUT_FILE_0}"
      SHELL
    end
  end
end
```

> aside positive
> The cache folder really is called `flutter_gemma`: the package was renamed, and this path was not. The build hook writes the stager and the dylibs there, and the phase name matches what the tooling expects, so leave both strings exactly as they are.

Build once and check that the staging worked:

```bash
flutter build macos --debug
ls build/macos/Build/Products/Debug/gemma_codelab.app/Contents/Frameworks
```

You should see `GemmaModelConstraintProvider.framework` and `LiteRtLmMetalAccelerator.framework` next to `LiteRtLm.framework`.

> aside positive
> **Already have a `macos/Podfile`** for another plugin? Then leave Swift Package Manager on and just add the block above to the Podfile you have.

## Initialize flutter_edge_ai
Duration: 0:03:00

flutter_edge_ai's core doesn't know how to run a model until you register an engine. You do that once, before `runApp`.

Replace `lib/main.dart`:

```dart
{{FILE:1/main.dart}}
```

`FlutterEdgeAi.initialize` sets up model storage and the download service, and `inferenceEngines` registers the engines you added. `LiteRtLmEngine` handles every `.litertlm` model.

> aside negative
> If you forget `inferenceEngines`, installing works but loading the model fails, because no registered engine can open the file.

The app doesn't compile yet because `DownloadScreen` doesn't exist. You create it in the next step.

## Download Gemma 4 E2B
Duration: 0:08:00

The model file is about 2.6 GB. Downloading it inside a build would make the app huge, so the app downloads it on first launch and keeps it on the device.

### Create a model service

Create `lib/gemma_service.dart`. It keeps the model URL, the install call and the loaded model in one place:

```dart
{{FILE:1/gemma_service.dart}}
```

Three details in this file matter:

* **`fileType: ModelFileType.litertlm`.** flutter_edge_ai doesn't infer the format from the file extension. Without it the install is recorded as a MediaPipe `.task` model, and the LiteRT-LM engine never picks it up.
* **`modelType: ModelType.gemma4`** selects Gemma 4's prompt format, including its native tool-call tokens.
* **`maxTokens: 4096`** is the *context window*: the prompt, the history and the reply together. Larger windows use more memory. `getActiveModel` is slow the first time, so `loadModel` keeps the instance in `_model` and reuses it.

### Create the download screen

Create `lib/download_screen.dart`. It checks whether the model is already installed. If it isn't, it shows a download button and a progress bar.

```dart
{{FILE:1/download_screen.dart}}
```

## Stream a chat response
Duration: 0:10:00

Now build the home screen and the first feature: a chat whose reply appears token by token.

### Create the home screen

Create `lib/home_screen.dart`:

```dart
{{FILE:1/home_screen.dart}}
```

### Create the chat screen

Create `lib/chat_screen.dart`:

```dart
{{FILE:1/chat_screen.dart}}
```

How a message flows:

1. `createChat` opens a conversation on the loaded model. `systemInstruction` sets its behavior for the whole chat.
2. `addQueryChunk` adds the user's message to the conversation.
3. `generateChatResponseAsync` returns a stream. Each `TextResponse` carries the next piece of the reply, and appending it inside `setState` makes the text appear as it's generated.

**Why these sampling values?** With wide sampling, small models sometimes switch language mid-sentence and drop in a word from another script. `temperature: 0.7, topK: 40, topP: 0.9`, together with an instruction that names the language, keeps replies readable without making them repetitive.

> aside positive
> **`createChat` or `openChat`?** `createChat` opens the *primary* conversation. The engine keeps one live conversation at a time, so creating a new one closes the previous one. `openChat` opens additional concurrent sessions, but on `.litertlm` models those sessions reject images. This app shows one screen at a time and needs images, so it uses `createChat` everywhere.

### Run it

```bash
flutter run
```

Tap **Download model** and wait for it to reach 100%. Then open **Chat** and ask something like *"In one sentence, why run a model on-device?"*

Opening the first chat after launch takes a few seconds while the model loads onto the GPU, and a spinner shows until it's ready. Other screens reuse the loaded model.

## Add vision
Duration: 0:08:00

Gemma 4 E2B understands images. Sending one is a different `Message` constructor. The model was already loaded with `supportImage: true` in `GemmaService`, and the chat was opened with `supportImage: true`.

Replace `lib/chat_screen.dart` with the version below. What changed:

* A photo button that calls `_pickImage`. Phones open the camera. Desktop has no camera source, so it opens a file picker.
* The picked image is scaled to at most 1024 px wide with `maxWidth`, so the app never holds a full-resolution photo in memory.
* `_send` uses `Message.withImage` when a photo is attached and falls back to a default question if the text field is empty.
* `ChatMessage` and `MessageBubble` show the photo in the conversation.

```dart
{{FILE:2/chat_screen.dart}}
```

Rename the home tile to reflect the new feature. In `lib/home_screen.dart`, update the tile:

```dart
DemoTile(
  icon: Icons.chat_bubble_outline,
  title: 'Chat & vision',
  subtitle: 'Ask about text or a photo',
  screen: ChatScreen(),
),
```

Run the app again, open **Chat & vision**, attach a photo and ask *"What do you see?"*

> aside negative
> Images only work on sessions opened with `createChat`. A session from `openChat` on a `.litertlm` model rejects image input with an error.

## Show the model's reasoning
Duration: 0:06:00

Gemma 4 can think before it answers. With `enableThinking: true`, the stream also emits `ThinkingResponse` events that carry the reasoning, followed by the normal `TextResponse` answer.

Replace `lib/chat_screen.dart` again. What changed:

* `ChatScreen` takes a `thinking` flag and passes it to `createChat` as `enableThinking`.
* The `if` on `TextResponse` becomes an exhaustive `switch` over the sealed `ModelResponse`. Reasoning goes into `ChatMessage.thinking`, and the answer into `text`.
* The bubble shows reasoning in an expandable **Reasoning** section. It starts open while the model is still thinking.

```dart
{{FILE:3/chat_screen.dart}}
```

Add a second tile to `lib/home_screen.dart`. The whole list now reads:

```dart
{{SNIPPET:3/home_screen.dart|children: const [|        ],}}
```

Open **Thinking** and try a question that punishes a quick answer:

*"A bat and a ball cost 1.10 in total. The bat costs 1.00 more than the ball. How much is the ball?"*

The reasoning streams first. Then the answer (0.05) appears below it.

> aside positive
> Thinking is set per chat, not per model. The Chat and Thinking screens share one loaded model, and only the conversation differs.

## Let the model call your code
Duration: 0:12:00

Function calling lets the model trigger actions in your app. You describe each tool with a name, a description and a JSON Schema for its arguments. When the model decides to use one, flutter_edge_ai parses the call, you run it, and the result goes back to the model so it can continue.

`generateChatResponseWithTools` runs that loop for you. You supply one callback, `onToolCall`.

Create `lib/tools_screen.dart`:

```dart
{{FILE:4/tools_screen.dart}}
```

Things to notice:

* **`tools` + `supportsFunctionCalls: true`** on `createChat` declare the tools. With `ModelType.gemma4`, flutter_edge_ai passes them to the model's native chat template instead of pasting them into the prompt text.
* **`onToolCall`** gets a `FunctionCallResponse` with `name` and `args`, and returns a `Map`. flutter_edge_ai sends that map back to the model and asks it to continue, until the model replies without calling a tool.
* **`_runTool` never throws.** If `onToolCall` throws, flutter_edge_ai records the error in the conversation and then rethrows it, which ends the stream. Returning `{'error': ...}` instead lets the model read what went wrong and respond to it.
* **`maxToolTurns: 5`** stops a model that keeps calling tools without ever answering.

> aside negative
> **Give every tool a `parameters` schema, even with no arguments.** `list_tasks` takes no arguments but still declares `{'type': 'object', 'properties': {}}`. With flutter_edge_ai 1.8.1, a tool that leaves `parameters` out makes generation fail with `Failed to start streaming (code: 13)`.

Finally, add the third tile. Replace `lib/home_screen.dart`:

```dart
{{FILE:4/home_screen.dart}}
```

Run the app, open **Tools** and try:

* *"Add a task to buy milk and make the app bar green."* The model calls `add_task` and then `set_color`.
* *"What is on my list?"* The model calls `list_tasks` and reads the result back.

Each tool call appears in the log as `→ name(args)`, so you can see exactly what the model asked for.

## Test it offline
Duration: 0:03:00

This is the step that shows the difference from a cloud API.

1. Make sure the model has finished downloading and you've sent at least one message.
2. Turn on **airplane mode**, or turn off Wi-Fi on your Mac.
3. Fully close the app and launch it again.
4. Use each screen: Chat, Vision, Thinking and Tools.

Everything still works. The download screen sees that the model is installed and goes straight to the home screen, and every response is generated on the device.

> aside positive
> Also try a release build with `flutter run --release`. That's the build your users get.

## Troubleshooting
Duration: 0:05:00

Problems you're likely to hit, and what fixes them.

### The model downloads but won't load

* Check `fileType: ModelFileType.litertlm` on `installModel`. The extension isn't inferred.
* Check that `FlutterEdgeAi.initialize` registers `LiteRtLmEngine()`.
* If you first installed with the wrong `fileType`, the app still treats the model as installed and skips the download screen. Uninstall the app, or clear its data, and install again.

### Tool calls show up as raw text

Make sure `createChat` gets `modelType: ModelType.gemma4`. Without it the chat uses an older Gemma prompt format. The tools become part of the prompt text, and the model's calls can come back as plain text instead of `FunctionCallResponse` events.

### `Failed to start streaming (code: 13)` on a tools chat

A tool is missing its `parameters` schema. Give it at least an empty object schema:

```dart
parameters: {'type': 'object', 'properties': <String, dynamic>{}},
```

### Answers contain `$x$` or other LaTeX

Gemma often formats math as LaTeX, even when asked not to. The system instruction reduces this but doesn't prevent it. To display it properly, render replies with a Markdown package that supports LaTeX, such as [gpt_markdown](https://pub.dev/packages/gpt_markdown).

### Words from another language appear in the reply

Narrow the sampling (`temperature`, `topK`, `topP`) and say in the system instruction which language to use, including for reasoning.

### Android: the download crashes on Android 14+

Add the `SystemForegroundService` override and `FOREGROUND_SERVICE_DATA_SYNC` from the Android setup step.

### Android: the app crashes when the engine starts

Check that you're on an arm64 device, not an x86_64 emulator, and that `abiFilters` is set.

### macOS: the engine fails to load

Open the built app's `Contents/Frameworks` folder. If `GemmaModelConstraintProvider.framework` is missing, the staging phase never ran: check that the `post_install` block is in `macos/Podfile` and run `flutter clean && flutter pub get` before building again.

### The app is killed while loading the model

The device ran out of memory. Close other apps, try a device with more RAM, or lower `maxTokens`.

## Congratulations
Duration: 0:02:00

You built a Flutter app that runs Gemma 4 on the device, with streaming chat, image understanding, visible reasoning and function calling. After the first download it needs no network, no API key and no server.

### Where to go next

* **Add voice.** [flutter_edge_ai_speech](https://pub.dev/packages/flutter_edge_ai_speech) adds on-device speech-to-text (Whisper Tiny listens for 30 seconds at a time) and text-to-speech (Inflect-Nano is English-only and the fastest of the three), so a whole speech-to-speech loop runs without a network.
* **Answer questions about your own documents.** `flutter_edge_ai_sqlite` and `flutter_edge_ai_qdrant` add on-device vector search for retrieval-augmented generation.
* **Give the model skills.** `flutter_edge_ai_agent` builds on function calling with reusable skills.
* **Explore the demo app.** [gemma-on-device-demo](https://github.com/jakansha2001/gemma-on-device-demo) is a more complete version of this app, with a hands-free voice loop, a larger set of tools and Markdown/LaTeX rendering.

### Resources

* [flutter_edge_ai documentation](https://flutteredge.ai)
* [flutter_edge_ai on pub.dev](https://pub.dev/packages/flutter_edge_ai)
* [Gemma 4 E2B LiteRT-LM model card](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)
* [Gemma documentation](https://ai.google.dev/gemma)
* [LiteRT-LM on GitHub](https://github.com/google-ai-edge/LiteRT-LM)

### About the author

This codelab was written by **Akansha Jain**: [Website](https://akanshajain.dev) · [LinkedIn](https://www.linkedin.com/in/akansha-jain-2001/) · [GitHub](https://github.com/jakansha2001) · [Medium](https://medium.com/@akansha.jain1611)
