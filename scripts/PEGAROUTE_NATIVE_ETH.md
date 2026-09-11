# Native ETH deposit execution

This increment enables public **native ETH on Ethereum mainnet → Instaswap
deposit orders**, using Cake's existing fee calculation, software-wallet signing,
confirmation screen, dispatcher and SQLite execution lifecycle. ETH → XMR is
covered end-to-end with mocked API responses and synthetic signed transactions.
Other catalog destinations may use the same deposit model when Instaswap returns
compatible instructions; they have not been live-validated.

The creation flow obtains a fresh address-bound quote, selects the Instaswap
deposit route, consumes the existing one-shot preflight, and returns a bound Trade
for Cake's ordinary initial save. Deposit address/amount and any supplied expiry
come from the authenticated order. Missing expiry is permitted. The source
transaction verifies the deposit payment; it does not prove provider payout or
refund behavior. Those remain bound order terms and polled provider evidence.

## Local execution bridge

The existing Python bridge remains quote-only by default. To opt in to creation,
status and source-hash notification, run manually with the existing server-side
credential file:

```sh
python3 scripts/pegaroute_quote_proxy.py \
  --upstream http://127.0.0.1:4000 --port 4003 \
  --key-file /path/to/existing/server-side-key-file --allow-execution
```

Use an available port; ports 4001 and 4002 were Docker-owned at the last check.
Cake and the bridge must agree on `PEGAROUTE_API_BASE_URL=http://127.0.0.1:4003`.
Provider credentials never enter the app. The opt-in bridge binds only loopback,
uses a fixed loopback upstream, rejects redirects, and allows only:

- `GET /quote`
- `POST /swap`
- `GET /swap/:id`
- `POST /swap/:id/txhash`

With the configured local development checkout, build using the existing runner:

```sh
PEGAROUTE_API_BASE_URL=http://127.0.0.1:4003 \
  bash scripts/macos/run_pegaroute_dev.sh --build-only
```

The runner uses a disposable snapshot and the existing native stubs. This checks
app integration; a funded ETH → XMR swap requires separate live validation.

## Broadcast and notification

The existing lifecycle stores the source hash before notification and prevents a
second funding commit, including from separately prepared instances. Notification
validates both Pegasus's stable transaction ID and the actual source hash. A
legacy `submitted` acknowledgement is **not** treated as persisted acceptance;
an authenticated status poll must return the same source hash. Callback failures
preserve successful local broadcast and failed/pending callback state. No worker
or automatic funding retry is added.

Stable Pegasus `dca607dc` already has the basic quote/create/status/txhash endpoints
needed by this flow. The isolated upstream commits `7c8a0001` (immutable hash
registration) and `b295a81d` (creation-attempt recovery) are not deployed and are
not prerequisites for this increment. The stable legacy hash endpoint can
acknowledge without proving persistence, hence status verification. Recovery of
a creation POST whose response was lost remains deferred; Cake blocks provider
fallback after that ambiguous POST.

## Retained and deferred work

Existing token catalogs, receive-amount estimator, binding envelopes, migrations,
BTC/XMR/THOR/Maya handler seams, and lifecycle/store tests are retained. Funding
still rejects contract calls, approvals, token sources, other source chains,
memos, private routes, hardware/UR, send-all and external funding. Fixed-rate
execution, OpenOcean semantics, approval sequencing, creation recovery, callback
outbox/retry UI and other source adapters are deferred.

Validation is offline: mocked HTTP, in-memory SQLite and synthetic test keys.
No real order creation, real-wallet signing, funding, broadcasting or native
backend build was performed for this increment.

Checks with Flutter 3.41.9:

- `flutter test --no-pub test/exchange test/view_model/send_view_model_commit_test.dart`:
  **279 passed**.
- Targeted `flutter analyze --no-pub --no-fatal-infos` across the changed Dart
  source and tests: **no errors or warnings**; informational style lints remain.
- `python3 -m unittest discover -s test/tools -p 'test_pegaroute_quote_proxy.py'`:
  **6 passed**, using a mocked loopback upstream only.
- Protected build/lockfile SHA-256 checks and `git diff --check`: passed.

Final review explicitly restricts the registered deposit handler to Instaswap;
an OpenOcean empty-calldata envelope does not qualify as a deposit order. The
focused deposit/handler suites and targeted analysis passed after that check.

Flutter reports existing missing `assets/new-ui/` directories while preparing
the test bundle; the test suite completes successfully without asset changes.
