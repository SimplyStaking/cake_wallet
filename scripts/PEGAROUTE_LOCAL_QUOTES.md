# Local Pegaroute quotes

Run from `feat/initial-pegaroute-integration`. The stable local API can run independently
of whichever branch is checked out in the Pegasus repository.

Start the quote-only bridge (Python standard library only):

```sh
python3 scripts/pegaroute_quote_proxy.py \
  --key-file /Users/thaabl/Documents/Synapse3/pegasus/LOCAL_CAKE_APIKEY.md
```

The bridge listens on `127.0.0.1:4001` and authenticates `GET /quote` to
`127.0.0.1:4000`. It reads the key file on each request, so local key rotation
does not require rebuilding Cake. It cannot forward swap creation or callbacks.
It neither modifies Pegasus nor loads its environment files.

If port 4001 belongs to another local service, use `--port 4002` when starting
the bridge and `PEGAROUTE_API_BASE_URL=http://127.0.0.1:4002` with the runner.
Use that same origin in the smoke test's `--dart-define`.

### macOS development runner

From the configured integration checkout, build and launch with:

```sh
bash scripts/macos/run_pegaroute_dev.sh
```

This uses Flutter from `PATH` (or `FLUTTER_BIN=/path/to/flutter`), Xcode, CocoaPods,
and the existing local development setup. It reuses a compatible disposable build
workspace, builds with the public origin `http://127.0.0.1:4003`, then starts Cake
with a fresh temporary profile and bundle ID. The proxy runs separately. For the
quote-only bridge above, set `PEGAROUTE_API_BASE_URL=http://127.0.0.1:4001`.

Compared with `scripts/macos/run_dev.sh`, the runner:

- Builds in a disposable workspace so generated files, lockfiles and build caches
  stay outside the primary checkout.
- Passes the Pegaroute origin through Flutter's generated Xcode configuration.
- Retains Pub, CocoaPods, build-runner and Xcode caches. Full build-runner graph
  validation is incremental; unchanged vector directories are reused, changed
  or missing outputs are rebuilt, and removed SVG outputs are cleaned up.
- Regenerates localization when its ARB/generator inputs or generated outputs
  change. Runner/launcher edits and primary generated-localization changes retain
  compatible build caches.
- Prints cache-hit/miss reasons, changed compatibility-input names, a warm/cold
  build plan, timestamped stage starts, durations, and vector-directory progress.
  A per-run log includes the cache decision and source sync as well as build output.
- Targets the host architecture explicitly (arm64 on Apple Silicon), verifies the
  ad-hoc signature, and retains per-build timing logs and separate app artifacts.
- Extends the temporary profile to include caches, application support and `TMPDIR`.

Both use the existing native-stub development configuration, Debug Xcode build,
development entitlements and a temporary bundle ID. The new runner inherits the
checkout's configured wallet/storage setup; this local setup uses in-memory secure
storage. It does not perform first-time Cake configuration.

Build without launching, force a clean workspace, adopt an older completed build,
or launch a retained app without recompiling:

```sh
bash scripts/macos/run_pegaroute_dev.sh --build-only
bash scripts/macos/run_pegaroute_dev.sh --clean --build-only
bash scripts/macos/run_pegaroute_dev.sh --incremental /path/to/pegaroute-macos-build.XXXXXX --build-only
bash scripts/macos/run_pegaroute_dev.sh --launch-only /path/to/pegaroute-macos-release.XXXXXX
```

Inspect cache selection before building (use the same configuration as the build):

```sh
ETHERSCAN_API_KEY_FILE="$PWD/docs/builds/ETHERSCAN_API_KEY.txt" \
  bash scripts/macos/run_pegaroute_dev.sh --cache-status
```

`--cache-status` prints the decision and creates a diagnostic log/input fingerprint
record; it does not sync, build, launch, or change the selected workspace. A cold
plan is announced before expensive work. Cache-change diagnostics print input
names, never credential/configuration values. Vector rebuild counts and reasons
appear before compilation, with progress as each directory completes.

Workspaces, app artifacts, logs and profiles are retained under `${TMPDIR}/opencode`
by default; set `CAKE_DEV_TMPDIR` to choose a different directory outside the
checkout. Ordinary source edits reuse the current cache. Changes to dependencies,
SDK/toolchain, generated source inputs, native project configuration, proxy origin
or the optional Etherscan configuration select a new workspace and retain the old
one. The runner uses an explicit workspace-layout version rather than hashing its
own script. Bump that version only when changing incompatible workspace preparation
rules. Localization has its own input/output fingerprints. Compatible workspaces
from the preceding runner are migrated in place after verifying their original
input fingerprint against the current inputs and retained runner; changed or
unverifiable legacy inputs select a fresh workspace. An explicit `--incremental`
path must be a runner build directly under that
temporary parent. Adopting an older runner build preserves its app and refreshes
its generated graph once; later builds use the warm graph.

The runner prints the workspace, app, log and relaunch paths. Each launch clones
the built app into its fresh profile and assigns that copy a unique bundle ID,
preserving prior artifacts and profiles. `--launch-only` also accepts older build
snapshot paths and uses their embedded proxy URL. Set a fresh PIN and create or
restore a wallet for each session; this local setup has in-memory secure storage.
For configured history, supply `ETHERSCAN_API_KEY_FILE` when building; its contents
are injected only into the disposable workspace and are never printed.

### Direct Flutter launch

For an already prepared checkout, run/rebuild Cake using the non-secret origin:

```sh
flutter run -d macos --dart-define=PEGAROUTE_API_BASE_URL=http://127.0.0.1:4001
```

Use the same `--dart-define` with your existing Flutter build command if you
launch through Xcode. A running app needs a restart/rebuild to pick up the define.
The override also accepts the deployed Cake HTTPS proxy; without it, the existing
generated `pegarouteApiBaseUrl` configuration is used. No localhost origin or
Pegasus credential is a default in the app.

Verify the actual Cake provider against the bridge with the opt-in read-only test:

```sh
flutter test --no-pub test/manual/pegaroute_quote_smoke_test.dart \
  --dart-define=RUN_PEGAROUTE_QUOTE_SMOKE=true \
  --dart-define=PEGAROUTE_API_BASE_URL=http://127.0.0.1:4001
```

This checks that `1 ETH → XMR` and `100 USDC (Ethereum) → XMR` return finite
positive rates and usable limits. Cataloged tokens on eligible source chains
participate in public floating-rate discovery. Amounts vary with
the market. No order, signing, funding, or broadcast is involved. Ordinary test
runs skip the live quote test. Quotes remain subject to the server's routing and
private-mode policy; Cake still rejects all private execution.
