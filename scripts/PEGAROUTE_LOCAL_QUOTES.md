# Local Pegaroute quotes

Run from `feat/pegaroute-integration`. The stable local API can run independently
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

Run/rebuild Cake using only the non-secret proxy origin:

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

This checks that `1 ETH → XMR` returns a finite positive rate. Amounts vary with
the market. No order, signing, funding, or broadcast is involved. Ordinary test
runs skip the live quote test. Quotes remain subject to the server's routing and
private-mode policy; Cake still rejects all private execution.
