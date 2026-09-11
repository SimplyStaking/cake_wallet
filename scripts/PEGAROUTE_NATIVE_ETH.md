# Pegaroute EVM execution

Pegaroute uses Cake's existing fee calculation, software-wallet signing,
confirmation screen, dispatcher and SQLite lifecycle. Supported execution shapes:

| Source | Funding operation | Providers |
| --- | --- | --- |
| Native asset on Ethereum, BSC, Base, Arbitrum or Polygon | Native transfer | Instaswap; compatible authenticated OpenOcean instructions |
| Native asset on those networks | Single contract call | THORChain, Maya, OpenOcean |
| Mapped ERC20 on those networks | One standard token transfer, zero native value | Instaswap |

These are wallet capabilities, **not a claim that every provider serves every
network or pair**. Pegasus supplies available routes. Destination assets are not
hardcoded: any mapped destination can be used when the selected provider returns
compatible instructions. OpenOcean routes are same-chain.

Creation obtains a fresh address-bound quote, selects the highest-output enabled
executable route, consumes the one-shot preflight and returns a bound Trade for
Cake's ordinary save. The authenticated execution snapshot, canonical assets,
exact source amount, sender, payout/refund intent, provider and wallet/network
are persisted together. Built-in token aliases are resolved to canonical typed
contract/mint identities before order creation. Supplied funding expiries are enforced; absent expiry
is permitted. Wallet preparation inspects actual signed type-2 or EIP-155 legacy
bytes to bind signer, chain, target, native value and exact calldata, and derives
the real network hash. Prepared bytes cannot change before commit.

## Trusted-provider model

**Cake trusts authenticated Pegaroute instructions for contract effects.**
Independent decoding of output asset, recipient, minimum return, nested calls,
fees, refunds and authority effects is explicitly deferred, with no work scheduled
for this increment. Incorrect or compromised upstream instructions could have
unintended effects even when their accompanying metadata matches the request.
The byte checks establish which transaction Cake signs, not what that contract
will ultimately do. Existing strict verifier seams are retained separately.

## Provider configuration

In the new swap UI, open **Swap providers → Pegaroute → Manage providers**.
Pegaroute remains one exchange entry. The Instaswap, THORChain, Maya and
OpenOcean toggles are saved locally; automatic selection respects them.

All four settings now show EVM execution support. Exchange comparison and fresh
creation use the same preference and execution-shape eligibility rules. Native
inputs can use enabled DEX routes when Instaswap is disabled; token-source DEX
routes remain excluded because approval/contract debit support is not activated.
The fresh creation quote may change the estimate; its chosen provider and output
are carried through the Trade and normal confirmation UI.

**Decentralized-only** includes Instaswap, like the other decentralized providers,
while respecting its saved enabled/disabled preference.
Changing settings refreshes limits/rates and discards results from older settings.
The read-only provider API retains broader native/token quote discovery and uses
the same preferences when supplied, including for receive-amount estimates.

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

The runner uses a disposable snapshot and the existing native stubs. The last
built app, snapshot `pegaroute-macos-build.S59BDZ` at `28177af6c`, predates provider
settings and trusted EVM execution. Rebuild to use these additions. Funded swaps
require separate live validation.

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
rejects approval sequences, token-source contract swaps, serialized transactions,
non-EVM sources, private routes, hardware/UR, send-all and external funding.
THOR/Maya contract memo metadata and calldata are trusted and bound together.
Fixed-rate execution, independent contract-effect validation, creation recovery,
callback outbox/retry UI and other source adapters are deferred.

Validation is offline: mocked HTTP, in-memory SQLite and synthetic test keys.
No real order creation, real-wallet signing, funding, broadcasting or native
backend build was performed for this increment.

Trusted EVM verification with Flutter 3.41.9: **334 tests passed** across `test/exchange`,
`test/view_model/send_view_model_commit_test.dart` and
`test/new-ui/widgets/swap_page/pegaroute_providers_settings_test.dart`.
Coverage includes synthetic native transfers/calls on all five EVM networks,
ETH → USDC contract instructions, ERC20 deposits with 6/18 decimals, SQLite
restoration/callbacks, altered signed instructions, wallet/network switches,
supplied expiry, unsupported approvals, preference changes, route ranking and
duplicate-commit prevention. Synthetic provider/network combinations exercise
plumbing without claiming live market availability. The local bridge is unchanged;
its earlier six mocked tests passed. No app rebuild was performed in this increment.
Targeted source/test analysis passed with no errors or warnings; existing
informational style lints remain. Protected-file checksums and `git diff --check` passed.

Flutter reports existing missing `assets/new-ui/` directories while preparing
the test bundle; the test suite completes successfully without asset changes.
