# Building Cake Wallet for Local Development

> **Initial draft — temporary development setup.** These macOS helpers and local
> workarounds are provisional scaffolding, not a supported or release-ready build
> workflow. Expect them to be revised or replaced. Native stubs, in-memory secure
> storage, and relaxed development entitlements are for disposable testing only;
> do not use this setup with real funds or production wallet data.

This guide covers setting up Cake Wallet for day-to-day development, where you can run the app with hot reload while making changes.

For release builds, please view the applicable platform guide in this directory instead (`ANDROID.md`, `IOS.md`, `MACOS.md`, `LINUX.md`, `WINDOWS.md`).

## Requirements and Setup

The following assumes building and running on macOS. For other platforms, follow the setup sections of the corresponding guide above first, then continue from step 5 below.

```txt
macOS 15+
Xcode 16+
Flutter 3.41.9
Rust (stable)
```

NOTE: use the same Flutter version as pinned in the repo's `Dockerfile` (currently `3.41.9`). Dependencies are pinned against this version, so newer versions may work but are not guaranteed.

### 1. Installing dependencies

You may easily install the required tools with [brew](https://brew.sh):

```zsh
brew install autoconf automake binutils ccache cmake cocoapods go libtool pigz pkg-config
sudo softwareupdate --install-rosetta --agree-to-license
```

### 2. Installing Xcode

Download and install [Xcode](https://developer.apple.com/xcode/) from the macOS App Store, then run:

```zsh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

### 3. Installing Flutter

Install Flutter `3.41.9`. As this is not necessarily the latest version, download it from <https://docs.flutter.dev/release/archive>.

### 4. Installing Rust

Install Rust from the [rustup.rs](https://rustup.rs/) website:

```zsh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Run `flutter doctor` and correct any problems before proceeding. The `sudo` commands above are only for system setup; the local build and run commands below do not require root access.

### 5. One-time project setup

Select the app variant you want to develop on (this sets the app name, bundle id, etc):

```zsh
cd scripts/macos/
source ./app_env.sh cakewallet
# source ./app_env.sh monero.com # Instead of the line above, if developing Monero.com
```

Configure the project. This generates `pubspec.yaml`, sets up icons, entitlements, etc:

```zsh
CAKE_MACOS_SKIP_SECURE_STORAGE=1 ./app_config.sh
```

### 6. Preparing Flutter

Change back to the root directory of the Cake Wallet source code and prepare generated files:

```zsh
cd ../../
flutter pub get
dart run tool/generate_new_secrets.dart
dart run tool/import_secrets_config.dart
dart run tool/generate_localization.dart
./model_generator.sh async
```

If dependency resolution hangs at `Resolving dependencies...`, check whether your git configuration rewrites GitHub HTTPS URLs to SSH. You can bypass that rewrite for this command with:

```zsh
GIT_CONFIG_GLOBAL=/dev/null flutter pub get
```

### 7. Selecting native dependencies

For a normal build, build the native libraries. NOTE: this only needs to be done once (or when native dependencies change), but will take quite a while, so be sure you grab a cup of coffee or a good book!

```zsh
cd scripts/macos/
./build_all.sh
```

For a GUI-only development build, skip the native libraries instead:

```zsh
CAKE_MACOS_SKIP_NATIVE=1 ./build_all.sh
```

This creates local placeholder libraries so the app can link and launch. Monero, Wownero, and MWEB wallet operations are not available in this mode.

The secure-storage switch configured in step 5 uses an in-memory implementation. Wallet passwords and settings stored there will not persist between runs.

NOTE: `generate_new_secrets.dart` creates placeholder API keys in `lib/.secrets.g.dart`. Do not commit real keys there.

### 8. Running the app

Run the locally signed development app:

```zsh
./run_dev.sh
```

The app is built under `build/macos-dev/` and launched with a temporary bundle identifier and data profile. This prevents its non-persistent keys from being used with wallet files or preferences from an earlier run and keeps development data out of the production profile. The temporary profile path is printed at launch and is not removed automatically.

This local profile uses no macOS capabilities, including Bluetooth, keychain access groups, network entitlements, and the app sandbox. Consequently it is intended for GUI testing only.

To use `flutter run` with hot reload instead, configure an Apple Development signing team in Xcode first.

## Developing for Android

Build the native dependencies by following `ANDROID.md` up to (but not including) the final `flutter build apk --release` step, then simply run:

```zsh
./run-android.sh
```

This wrapper updates `android/app.properties` based on your current git branch, so development builds install alongside any production build of the app instead of overwriting it.

## Before opening a pull request

Format your changes and run the tests:

```zsh
./scripts/lint.sh
flutter test
```
