#!/bin/bash

# Build in an isolated workspace, retaining incremental compiler caches.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SOURCE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
PROXY_URL=${PEGAROUTE_API_BASE_URL:-http://127.0.0.1:4003}
TEMP_ROOT=${CAKE_DEV_TMPDIR:-${TMPDIR:-/tmp}/opencode}
MODE=run
BUILD_ROOT=
CLEAN=0
REUSE_ROOT=

copy_app() {
    # APFS clones retain old artifacts without copying every binary block.
    /bin/cp -cR "$1" "$2" 2>/dev/null || /usr/bin/ditto "$1" "$2"
}

timed() {
    local label="$1" started=$SECONDS
    shift
    echo "[$(date '+%H:%M:%S')] Stage START: $label (elapsed ${SECONDS}s)"
    "$@"
    echo "Timing: $label $((SECONDS - started))s"
}

usage() {
    cat <<'EOF'
Usage: scripts/macos/run_pegaroute_dev.sh [--clean | --incremental SNAPSHOT] [--build-only | --cache-status]
       scripts/macos/run_pegaroute_dev.sh --launch-only SNAPSHOT

By default, reuse this checkout's compatible disposable build workspace, build
a macOS Debug app with native stubs, and launch a fresh profile and app copy.

  --build-only             Build and print the app/snapshot paths without launching.
  --cache-status           Explain cache selection without building or launching.
  --clean                  Build in a new workspace, retaining previous caches.
  --incremental SNAPSHOT   Reuse a previous runner workspace (including older builds).
  --launch-only SNAPSHOT   Launch an existing snapshot without rebuilding.
  --help                   Show this help.

Environment for builds:
  PEGAROUTE_API_BASE_URL   Public Cake proxy origin (default http://127.0.0.1:4003).
  FLUTTER_BIN             Flutter executable (default flutter from PATH).
  CAKE_DEV_TMPDIR         Parent directory for snapshots and isolated profiles.
  ETHERSCAN_API_KEY_FILE  Optional plain key file for history in the disposable build.

The quote proxy must be running separately; see scripts/PEGAROUTE_LOCAL_QUOTES.md.
Dependency, generated-input, SDK and build-configuration changes select a fresh
workspace automatically, with changed input names logged (never their values).
Runner/launcher and localization edits retain compatible caches. Ordinary source
changes use incremental code generation and native compilation; unchanged vector
assets and dependencies are reused. Stage starts and asset progress are logged.
Each successful build retains a separate app artifact and a uniquely named log.
Snapshots, profiles, and logs are retained. --launch-only uses the configuration
already built into the app. No Pegasus credential is read by this runner.
An optional Etherscan key is configured only inside the disposable snapshot.
Each launch starts fresh: set a PIN and create or restore a wallet for that
session. This development build's in-memory credentials are lost on app exit.
The local app is re-signed with a fresh bundle ID to isolate macOS preferences.
The launcher returns after starting the app in its own process session; output
is written directly to the fresh profile's app.log.
Stale Pegaroute generated inputs and the Tor stub are refreshed only in the
snapshot; the source checkout's generated configuration remains intact.
EOF
}

fail() {
    echo "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --build-only) MODE=build; shift ;;
        --cache-status) MODE=status; shift ;;
        --clean) CLEAN=1; shift ;;
        --incremental)
            [[ $# -ge 2 ]] || fail "--incremental needs a workspace path."
            REUSE_ROOT=$(CDPATH= cd -- "$2" && pwd -P)
            shift 2
            ;;
        --launch-only)
            [[ $# -eq 2 && "$MODE" == run && "$CLEAN" == 0 && -z "$REUSE_ROOT" ]] ||
                fail "Use --launch-only on its own."
            MODE=launch
            BUILD_ROOT=$(CDPATH= cd -- "$2" && pwd -P)
            shift 2
            ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$CLEAN" == 0 || -z "$REUSE_ROOT" ]] || fail "Choose --clean or --incremental."

[[ $(uname -s) == Darwin ]] || fail "This runner requires macOS."
mkdir -p "$TEMP_ROOT"
TEMP_ROOT=$(CDPATH= cd -- "$TEMP_ROOT" && pwd -P)
RUN_LOG=$(mktemp "$TEMP_ROOT/pegaroute-macos-run.XXXXXX")
exec > >(tee "$RUN_LOG") 2>&1
echo "Run log (cache decisions and all stages): $RUN_LOG"
LOCK_ROOT=
finish_run() {
    local status=$?
    if [[ -n "$LOCK_ROOT" ]]; then
        rmdir "$LOCK_ROOT/.pegaroute-build-lock" || true
    fi
    if [[ "$status" == 0 ]]; then
        echo "[$(date '+%H:%M:%S')] Run complete (elapsed ${SECONDS}s). Log: $RUN_LOG"
    else
        echo "[$(date '+%H:%M:%S')] Run FAILED (exit $status, elapsed ${SECONDS}s). Log: $RUN_LOG"
    fi
}
trap finish_run EXIT

if [[ "$MODE" != launch ]]; then
    # Resolve the SDK before changing directories, and use its matching Dart.
    FLUTTER_BIN=$(command -v "${FLUTTER_BIN:-flutter}") || fail "Flutter was not found. Set FLUTTER_BIN."
    FLUTTER_DIR=$(CDPATH= cd -- "$(dirname -- "$FLUTTER_BIN")" && pwd -P)
    FLUTTER_BIN="$FLUTTER_DIR/$(basename -- "$FLUTTER_BIN")"
    export PATH="$FLUTTER_DIR:$PATH"
    for tool in dart pod rsync xcodebuild codesign; do
        command -v "$tool" >/dev/null || fail "Required build tool not found: $tool"
    done
    for input in pubspec.yaml lib/.secrets.g.dart macos/Runner/Info.plist \
        macos/Runner/Configs/AppInfo.xcconfig scripts/macos/build_dev_stubs.sh \
        scripts/macos/Dev.entitlements; do
        [[ -f "$SOURCE_DIR/$input" ]] || fail "Missing local development setup: $input"
    done
    case "$TEMP_ROOT/" in
        "$SOURCE_DIR/"*) fail "CAKE_DEV_TMPDIR must be outside the source checkout." ;;
    esac

    CHECKOUT_KEY=$(printf '%s' "$SOURCE_DIR" | shasum -a 256 | cut -c1-16)
    CACHE_POINTER="$TEMP_ROOT/pegaroute-macos-cache.$CHECKOUT_KEY.path"
    ADOPT=0
    if [[ "$CLEAN" == 0 ]]; then
        if [[ -n "$REUSE_ROOT" ]]; then
            BUILD_ROOT="$REUSE_ROOT"
            [[ -f "$BUILD_ROOT/.pegaroute-cache-key" ]] || ADOPT=1
        elif [[ -f "$CACHE_POINTER" ]]; then
            BUILD_ROOT=$(cat "$CACHE_POINTER")
        fi
    fi
    if [[ -n "$BUILD_ROOT" ]]; then
        [[ "$(dirname -- "$BUILD_ROOT")" == "$TEMP_ROOT" &&
            "$(basename -- "$BUILD_ROOT")" == pegaroute-macos-build.* &&
            -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" && ! -e "$BUILD_ROOT/.git" ]] ||
            fail "Expected a runner build workspace directly inside CAKE_DEV_TMPDIR."
        if [[ "$ADOPT" == 1 ]]; then
            [[ -f "$BUILD_ROOT/build-pegaroute-dev.log" &&
                -f "$BUILD_ROOT/macos/Runner/Configs/AppInfo.xcconfig" ]] ||
                fail "This is not a prepared runner snapshot."
        fi
    fi
    echo "[$(date '+%H:%M:%S')] Inspecting cache compatibility..."
    CACHE_INPUTS=$(mktemp "$TEMP_ROOT/pegaroute-macos-inputs.XXXXXX")
    CACHE_RESULT=$(python3 - "$SOURCE_DIR" "$FLUTTER_BIN" "$PROXY_URL" \
        "${ETHERSCAN_API_KEY_FILE:-}" "$BUILD_ROOT" "$CLEAN" "$ADOPT" "$CACHE_INPUTS" <<'PY'
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys

root, flutter, proxy, key_file, candidate, clean, adopt, output = sys.argv[1:]
root = Path(root).resolve()
fingerprint = lambda data: hashlib.sha256(data).hexdigest()
# Bump only for incompatible prepared-workspace rules, not script/text edits.
inputs = {'workspace layout': fingerprint(b'pegaroute-dev-layout-v2'),
          'checkout': fingerprint(str(root).encode()), 'proxy origin': fingerprint(proxy.encode())}
# Reproduce the preceding runner's identity to safely migrate a completed v1
# workspace without discarding its caches merely because this script changed.
legacy = hashlib.sha256(b'pegaroute-dev-cache-v1')
legacy.update(str(root).encode())
legacy.update(proxy.encode())
for name, command in [('Flutter SDK', [flutter, '--version', '--machine']),
                      ('Xcode', ['xcodebuild', '-version']),
                      ('CocoaPods', ['pod', '--version']), ('architecture', ['uname', '-m'])]:
    value = subprocess.check_output(command)
    inputs[name] = fingerprint(value)
    legacy.update(value)
skip = {'.git', '.dart_tool', 'build', 'Pods', '.symlinks', 'ephemeral',
        '.gradle', '.cxx', 'torch_dart', 'node_modules'}
names = {'pubspec.yaml', 'pubspec.lock', 'build.yaml', 'Podfile', 'Podfile.lock',
         'Info.plist', 'AppInfo.xcconfig', 'project.pbxproj'}
runner_path = 'scripts/macos/run_pegaroute_dev.sh'
legacy_runner = Path(candidate, runner_path) if candidate else None
for directory, dirs, files in os.walk(root, followlinks=False):
    dirs[:] = sorted(d for d in dirs if d not in skip and not Path(directory, d).is_symlink())
    for name in sorted(files):
        file = Path(directory, name)
        relative = file.relative_to(root).as_posix()
        compatible_input = (name in names or name.endswith(('.g.dart', '.vec', '.xcconfig', '.dylib')) or
                            relative in {'scripts/macos/build_all.sh', 'scripts/macos/build_dev_stubs.sh',
                                         'scripts/macos/Dev.entitlements'})
        legacy_input = compatible_input or relative == runner_path or name in {'i18n.dart', 'locales.dart'}
        if legacy_input and file.is_file() and not file.is_symlink():
            data = file.read_bytes()
            if compatible_input:
                inputs[relative] = fingerprint(data)
            if relative == runner_path and legacy_runner and legacy_runner.is_file():
                data = legacy_runner.read_bytes()
            legacy.update(relative.encode())
            legacy.update(hashlib.sha256(data).digest())
key_data = Path(key_file).read_bytes() if key_file else None
inputs['Etherscan configuration'] = fingerprint(key_data) if key_data is not None else 'absent'
if key_data is not None:
    legacy.update(hashlib.sha256(key_data).digest())
key = fingerprint(json.dumps(inputs, sort_keys=True).encode())
Path(output).write_text(json.dumps({'version': 2, 'key': key, 'inputs': inputs}, sort_keys=True))

def report(message):
    print(message, file=sys.stderr, flush=True)

reuse = False
if clean == '1':
    report('Cache MISS: explicit --clean; starting a new workspace.')
elif not candidate:
    report('Cache MISS: no previous workspace is selected.')
elif adopt == '1':
    reuse = True
    report(f'Cache ADOPT: {candidate}; preserve its app and refresh its generated graph once.')
else:
    workspace = Path(candidate)
    try:
        owner = (workspace / '.pegaroute-owner').read_text().strip()
        old_key = (workspace / '.pegaroute-cache-key').read_text().strip()
        manifest_path = workspace / '.pegaroute-cache-inputs.json'
        previous = json.loads(manifest_path.read_text()) if manifest_path.is_file() else None
        if owner != str(root):
            report('Cache MISS: workspace belongs to a different checkout.')
        elif previous is None:
            reuse = old_key == legacy.hexdigest() and legacy_runner.is_file()
            if reuse:
                report('Cache HIT: verified legacy inputs; upgrading cache metadata in place.')
            else:
                report('Cache MISS: legacy inputs differ (no per-input manifest is available).')
        elif not isinstance(previous, dict) or previous.get('version') != 2 or previous.get('key') != old_key or not isinstance(previous.get('inputs'), dict):
            report('Cache MISS: incompatible or incomplete cache metadata.')
        else:
            old = previous['inputs']
            changed = sorted(name for name in old.keys() | inputs.keys() if old.get(name) != inputs.get(name))
            reuse = not changed and old_key == key
            if reuse:
                report('Cache HIT: all compatibility inputs match.')
            else:
                report('Cache MISS: compatibility inputs changed:')
                for name in changed:
                    kind = 'added' if name not in old else 'removed' if name not in inputs else 'changed'
                    report(f'  {kind}: {name}')
    except (OSError, ValueError, TypeError):
        report('Cache MISS: cache metadata is missing or unreadable.')
if reuse:
    report(f'Reusing workspace: {candidate}')
    report('Build plan: reuse compatible Pub/Pods and native caches; check localization, code generation and vectors incrementally.')
else:
    if candidate:
        report(f'Retaining previous workspace: {candidate}')
    report('Build plan: COLD workspace; dependency setup, full code generation, all vector directories and native compilation may take several minutes.')
report('Runner/launcher edits and generated localization do not invalidate the workspace; localization inputs are checked separately.')
print(key, int(reuse))
PY
)
    read -r CACHE_KEY CACHE_REUSE <<< "$CACHE_RESULT"
    [[ "$MODE" != status ]] || exit 0
    [[ "$CACHE_REUSE" == 1 ]] || BUILD_ROOT=
    WARM=0
    if [[ -z "$BUILD_ROOT" ]]; then
        BUILD_ROOT=$(mktemp -d "$TEMP_ROOT/pegaroute-macos-build.XXXXXX")
    else
        WARM=1
    fi
    mkdir "$BUILD_ROOT/.pegaroute-build-lock" 2>/dev/null ||
        fail "This workspace is already being built: $BUILD_ROOT"
    LOCK_ROOT="$BUILD_ROOT"
    printf '%s\n' "$SOURCE_DIR" > "$BUILD_ROOT/.pegaroute-owner"
    echo "Build workspace: $BUILD_ROOT (incremental=$WARM)"
    echo "Public quote proxy: $PROXY_URL"
    echo "Using the existing native-stub development configuration."
    # Older workspaces did not archive app artifacts. Preserve that app before
    # adopting its caches; later builds always archive their own result below.
    if [[ "$ADOPT" == 1 ]]; then
        OLD_APP="$BUILD_ROOT/build/macos-dev/Build/Products/Debug/Cake Wallet.app"
        [[ -d "$OLD_APP" ]] || fail "The adopted snapshot has no built app."
        codesign --verify --deep --strict "$OLD_APP"
        SAVED=$(mktemp -d "$TEMP_ROOT/pegaroute-macos-release.XXXXXX")
        mkdir -p "$SAVED/build/macos-dev/Build/Products/Debug" "$SAVED/scripts/macos"
        copy_app "$OLD_APP" "$SAVED/build/macos-dev/Build/Products/Debug/Cake Wallet.app"
        cp "$BUILD_ROOT/scripts/macos/Dev.entitlements" "$SAVED/scripts/macos/Dev.entitlements"
        cp "$BUILD_ROOT/build-pegaroute-dev.log" "$SAVED/build-pegaroute-dev.log"
        echo "Preserved previous app: $SAVED"
    fi
    EXTRA_EXCLUDES=(--exclude='.pegaroute-*')
    if [[ "$WARM" == 1 && "$ADOPT" == 0 ]]; then
        # These prepared outputs differ intentionally from the protected source
        # checkout. Their source inputs participate in CACHE_KEY above.
        EXTRA_EXCLUDES+=(--exclude='*.g.dart' --exclude='*.vec'
            --exclude='/lib/generated'
            --exclude='/macos/Runner/Info.plist'
            --exclude='/macos/Runner/Configs/AppInfo.xcconfig'
            --exclude='/macos/Podfile.lock' --exclude='/pubspec.lock')
    fi
    timed 'source sync' rsync -a --checksum --delete --safe-links \
        --exclude='.git' --exclude='.dart_tool' --exclude='build' \
        --exclude='Pods' --exclude='.symlinks' --exclude='ephemeral' \
        --exclude='.gradle' --exclude='.cxx' --exclude='*.log' \
        --exclude='ETHERSCAN_API_KEY.txt' --exclude='.*secrets-config.json' \
        --exclude='/scripts/torch_dart' --exclude='/build-pegaroute-dev.*' \
        --exclude='node_modules' \
        "${EXTRA_EXCLUDES[@]}" \
        "$SOURCE_DIR/" "$BUILD_ROOT/"

    # The primary checkout can retain generated configuration from before the
    # integration branch. The public origin is supplied by dart-define below.
    python3 - "$BUILD_ROOT/lib/.secrets.g.dart" <<'PY'
from pathlib import Path
import re
import sys

target = Path(sys.argv[1])
text = target.read_text()
if not re.search(r"\bpegarouteApiBaseUrl\s*=", text):
    target.write_text(text.rstrip() + "\nconst pegarouteApiBaseUrl = '';\n")
    print("Public Pegaroute configuration refreshed in disposable snapshot.")
PY

    if [[ -n "${ETHERSCAN_API_KEY_FILE:-}" ]]; then
        python3 - "$ETHERSCAN_API_KEY_FILE" "$BUILD_ROOT/cw_evm/lib/.secrets.g.dart" <<'PY'
from pathlib import Path
import json
import re
import sys

key = Path(sys.argv[1]).read_text().strip()
if not re.fullmatch(r"[A-Za-z0-9]+", key):
    raise SystemExit("Expected a plain Etherscan API key")
target = Path(sys.argv[2])
text, count = re.subn(
    r"(\betherScanApiKey\s*=\s*)(['\"])[^'\"\r\n]*\2\s*;",
    lambda match: match[1] + json.dumps(key) + ";",
    target.read_text(),
)
if count != 1:
    raise SystemExit("Expected one generated Etherscan key declaration")
if target.read_text() != text:
    target.write_text(text)
print("Etherscan history credential configured in disposable snapshot.")
PY
    fi

    build_app() (
        cd "$BUILD_ROOT"
        export COCOAPODS_DISABLE_STATS=true
        local bundle_id="com.cakewallet.local.pegaroute.build${CACHE_KEY:0:16}"
        local arch
        arch=$(uname -m)

        # Recreate the established Tor stub before resolving its local path.
        CAKE_MACOS_SKIP_NATIVE=1 bash scripts/macos/build_all.sh
        if [[ "$ADOPT" == 1 || ! -f .dart_tool/package_config.json ]]; then
            timed 'pub get' "$FLUTTER_BIN" pub get --offline
        else
            echo "Reusing resolved Pub dependencies."
        fi
        timed 'localization' python3 - <<'PY'
from pathlib import Path
import hashlib
import json
import subprocess

state_file = Path('.pegaroute-localization.json')
inputs = sorted(Path('res/values').glob('*.arb')) + sorted(Path('tool').rglob('*.dart'))
digest = hashlib.sha256()
for file in inputs:
    digest.update(str(file).encode())
    digest.update(file.read_bytes())
    if file.suffix == '.arb':
        json.loads(file.read_text())
outputs = [Path('lib/generated/i18n.dart'), Path('lib/generated/locales.dart')]
def state():
    return {'inputs': digest.hexdigest(), 'outputs': {
        str(file): hashlib.sha256(file.read_bytes()).hexdigest() if file.is_file() else None
        for file in outputs}}
if state_file.is_file() and json.loads(state_file.read_text()) == state():
    print('Localization cache HIT: reusing generated localization.', flush=True)
else:
    print('Localization cache MISS: inputs changed, outputs changed/missing, or no prior metadata; regenerating.', flush=True)
    # The generator reports some failures without a nonzero exit. Remove only
    # these disposable outputs first so a failure cannot silently keep old text.
    for file in outputs:
        file.unlink(missing_ok=True)
    subprocess.run(['dart', 'run', 'tool/generate_localization.dart'], check=True)
    if any(not file.is_file() or not file.stat().st_size for file in outputs):
        raise SystemExit('Localization generation did not produce the expected files')
    state_file.write_text(json.dumps(state(), sort_keys=True))
    print('Localization regenerated in disposable workspace.')
PY
        # Keep the complete graph: filtered generation can delete unrelated
        # copied outputs. A warm graph only regenerates changed inputs.
        if [[ "$ADOPT" == 1 ]]; then
            # Older runners copied stale generated inputs. Reconcile those once
            # while retaining their expensive native compilation products.
            timed 'adopt generated graph' dart run build_runner clean
        fi
        timed 'code generation' dart run build_runner build
        timed 'vector assets' python3 - <<'PY'
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import hashlib
import json
import subprocess
import time

state_file = Path('.pegaroute-assets.json')
previous = json.loads(state_file.read_text()) if state_file.exists() else {}
current = {}
jobs = []
for source, destination in [(Path('assets/images'), Path('assets/images')),
                            (Path('res/pictures'), Path('assets/new-ui'))]:
    for directory in sorted({file.parent for file in source.rglob('*.svg')}):
        output = destination / directory.relative_to(source)
        files = sorted(directory.glob('*.svg'))
        digest = hashlib.sha256()
        for file in files:
            digest.update(file.name.encode())
            digest.update(file.read_bytes())
        key = str(directory)
        current[key] = {'hash': digest.hexdigest(),
                        'outputs': [str(output / (file.name + '.vec')) for file in files]}
        if previous.get(key) != current[key] or any(
                not Path(file).is_file() or Path(file).stat().st_size == 0
                for file in current[key]['outputs']):
            reason = ('no cached directory' if key not in previous else
                      'SVG inputs changed' if previous.get(key) != current[key] else
                      'compiled output missing or empty')
            jobs.append((directory, output, reason))

def compile_directory(job):
    source, output, reason = job
    started = time.monotonic()
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['dart', 'run', 'vector_graphics_compiler', '--input-dir', str(source),
                    '--out-dir', str(output), '--concurrency=4'], check=True)
    return source, round(time.monotonic() - started, 1)

print(f'Vector plan: {len(jobs)} directories to rebuild, {len(current) - len(jobs)} to reuse.', flush=True)
for directory, _, reason in jobs:
    print(f'  rebuild {directory}: {reason}', flush=True)
with ThreadPoolExecutor(max_workers=4) as executor:
    futures = [executor.submit(compile_directory, job) for job in jobs]
    for completed, future in enumerate(as_completed(futures), 1):
        source, seconds = future.result()
        print(f'Vector progress: {completed}/{len(jobs)} completed: {source} ({seconds}s)', flush=True)
old_outputs = {file for entry in previous.values() for file in entry['outputs']}
new_outputs = {file for entry in current.values() for file in entry['outputs']}
for file in old_outputs - new_outputs:
    path = Path(file)
    if not path.resolve().is_relative_to(Path('assets').resolve()) or not file.endswith('.svg.vec'):
        raise SystemExit('Unexpected cached vector output path')
    path.unlink(missing_ok=True)
state_file.write_text(json.dumps(current, sort_keys=True))
print(f'Vector directories: {len(jobs)} rebuilt, {len(current) - len(jobs)} reused.')
PY
        # The graphics script launches parallel jobs. Verify every expected
        # output before packaging, including failures in an earlier worker.
        while IFS= read -r -d '' svg; do
            [[ -s "assets/new-ui/${svg#res/pictures/}.vec" ]] ||
                fail "Missing compiled new-UI asset: $svg"
        done < <(find res/pictures -type f -name '*.svg' -print0)
        "$FLUTTER_BIN" build macos --debug --config-only --no-pub \
            --dart-define="PEGAROUTE_API_BASE_URL=$PROXY_URL"
        if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' macos/Runner/Info.plist)" != "$bundle_id" ]]; then
            /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" macos/Runner/Info.plist
        fi
        python3 - "$bundle_id" <<'PY'
from pathlib import Path
import re
import sys
file = Path('macos/Runner/Configs/AppInfo.xcconfig')
old = file.read_text()
new = re.sub(r'^PRODUCT_BUNDLE_IDENTIFIER = .*$',
             'PRODUCT_BUNDLE_IDENTIFIER = ' + sys.argv[1], old, flags=re.M)
if new != old:
    file.write_text(new)
PY
        if [[ "$ADOPT" == 1 || ! -f .pegaroute-pods-ready ||
            ! -f macos/Pods/Manifest.lock ]] ||
            ! cmp -s macos/Podfile.lock macos/Pods/Manifest.lock; then
            timed 'pod install' pod install --project-directory=macos
            touch .pegaroute-pods-ready
        else
            echo "Reusing CocoaPods installation."
        fi
        timed 'xcodebuild' xcodebuild \
            -workspace macos/Runner.xcworkspace \
            -scheme Runner \
            -configuration Debug \
            -destination "platform=macOS,arch=$arch" \
            -derivedDataPath "$BUILD_ROOT/build/macos-dev" \
            build \
            ARCHS="$arch" ONLY_ACTIVE_ARCH=YES \
            CODE_SIGN_ENTITLEMENTS="$BUILD_ROOT/scripts/macos/Dev.entitlements" \
            CODE_SIGN_IDENTITY='-' \
            CODE_SIGN_STYLE=Automatic \
            PROVISIONING_PROFILE_SPECIFIER='' \
            DEVELOPMENT_TEAM=''
        codesign --verify --deep --strict \
            "$BUILD_ROOT/build/macos-dev/Build/Products/Debug/Cake Wallet.app"
    )
    # pipefail preserves build failures while keeping a reusable build log.
    BUILD_LOG=$(mktemp "$BUILD_ROOT/build-pegaroute-dev.XXXXXX")
    echo "Build log: $BUILD_LOG"
    timed 'build total' build_app 2>&1 | tee "$BUILD_LOG"
    printf '%s\n' "$CACHE_KEY" > "$BUILD_ROOT/.pegaroute-cache-key"
    cp "$CACHE_INPUTS" "$BUILD_ROOT/.pegaroute-cache-inputs.json"
    printf '%s\n' "$BUILD_ROOT" > "$CACHE_POINTER"
    echo "Incremental workspace: $BUILD_ROOT"
    RELEASE_ROOT=$(mktemp -d "$TEMP_ROOT/pegaroute-macos-release.XXXXXX")
    mkdir -p "$RELEASE_ROOT/build/macos-dev/Build/Products/Debug" "$RELEASE_ROOT/scripts/macos"
    copy_app "$BUILD_ROOT/build/macos-dev/Build/Products/Debug/Cake Wallet.app" \
        "$RELEASE_ROOT/build/macos-dev/Build/Products/Debug/Cake Wallet.app"
    cp "$BUILD_ROOT/scripts/macos/Dev.entitlements" "$RELEASE_ROOT/scripts/macos/Dev.entitlements"
    cp "$BUILD_LOG" "$RELEASE_ROOT/build-pegaroute-dev.log"
    printf '%s\n' "$BUILD_ROOT" > "$RELEASE_ROOT/build-workspace.path"
    rmdir "$BUILD_ROOT/.pegaroute-build-lock"
    LOCK_ROOT=
    BUILD_ROOT="$RELEASE_ROOT"
fi

APP_PATH="$BUILD_ROOT/build/macos-dev/Build/Products/Debug/Cake Wallet.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Cake Wallet"
[[ -x "$APP_EXECUTABLE" ]] || fail "Built app not found: $APP_PATH"
echo "App: $APP_PATH"
printf 'Relaunch: bash %q --launch-only %q\n' "$SCRIPT_DIR/run_pegaroute_dev.sh" "$BUILD_ROOT"
[[ "$MODE" != build ]] || exit 0

# Secure storage is in-memory, so persisted wallet profiles cannot be reopened.
DEV_PROFILE_DIR=$(mktemp -d "$TEMP_ROOT/cake-pegaroute-profile.XXXXXX")
# The built release and all previous running copies retain their bundle IDs.
copy_app "$APP_PATH" "$DEV_PROFILE_DIR/Cake Wallet.app"
APP_PATH="$DEV_PROFILE_DIR/Cake Wallet.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Cake Wallet"
# macOS preferences follow the bundle ID, even with a different HOME.
CURRENT_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
[[ "$CURRENT_BUNDLE_ID" == com.cakewallet.local.pegaroute.* ]] || fail "Expected a local Pegaroute development app."
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.cakewallet.local.pegaroute.session$(date +%s).$$" \
    "$APP_PATH/Contents/Info.plist"
codesign --force --sign - --entitlements "$BUILD_ROOT/scripts/macos/Dev.entitlements" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
mkdir -p "$DEV_PROFILE_DIR/Library/Preferences" "$DEV_PROFILE_DIR/Library/Caches" \
    "$DEV_PROFILE_DIR/Library/Application Support" "$DEV_PROFILE_DIR/Documents" \
    "$DEV_PROFILE_DIR/tmp"
echo "Development profile: $DEV_PROFILE_DIR"
echo "App log: $DEV_PROFILE_DIR/app.log"
echo "Fresh session: set a PIN and create or restore a wallet."
python3 - "$APP_EXECUTABLE" "$DEV_PROFILE_DIR" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

app, profile = sys.argv[1:]
env = dict(os.environ, CAKE_WALLET_DIR=f"{profile}/Documents",
           CFFIXED_USER_HOME=profile, HOME=profile, TMPDIR=f"{profile}/tmp/")
with (Path(profile) / "app.log").open("ab", buffering=0) as log:
    process = subprocess.Popen([app], env=env, stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT,
                               start_new_session=True)
print(f"Detached app PID: {process.pid}")
PY
