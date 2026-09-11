# Pegaroute wallet execution

Pegaroute uses Cake's existing fee calculation, software-wallet signing,
confirmation screen, dispatcher and SQLite lifecycle. Supported execution shapes:

| Source | Funding operation | Providers |
| --- | --- | --- |
| Native asset on Ethereum, BSC, Base, Arbitrum or Polygon | Native transfer | Instaswap; compatible authenticated OpenOcean instructions |
| Native asset on those networks | Single contract call | THORChain, Maya, OpenOcean |
| Mapped ERC20 on those networks | One standard token transfer, zero native value | Instaswap |
| Mapped ERC20 on those networks | Single contract call, zero native value, no new approval needed | THORChain, Maya, OpenOcean |
| BTC, BCH, LTC, DOGE | Exact deposit with optional UTF-8 OP_RETURN memo; ordinary non-MWEB path | Compatible Instaswap, THORChain, Maya instructions |
| XMR | One memo-free deposit with one transaction ID | Compatible deposit instructions |
| Native SOL and mapped SPL | Memo-free deposit; SPL destination is an owner address | Compatible deposit instructions; SPL via Instaswap |
| Native TRX | Memo-free deposit | Compatible deposit instructions |
| ZEC | Memo-free deposit supported by Cake's existing builder, with extra balance for fees | Compatible deposit instructions |
| Native SOL and mapped SPL | Supplied legacy/v0 transaction, wallet as fee payer | OpenOcean |

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
is permitted. EVM preparation inspects actual signed type-2 or EIP-155 legacy
bytes to bind signer, chain, target, native value and exact calldata, and derives
the real network hash. Prepared EVM bytes cannot change before commit.

Deposits use fresh immutable bound outputs through Cake's wallet credentials.
UTXO memos are explicitly UTF-8-to-hex encoded for Cake's OP_RETURN builder;
XMR/SOL/TRON/ZEC required memos remain excluded. Supplied Solana transactions
use a small wallet `createTransaction` credential path: check mainnet and fee
payer, preserve the legacy/v0 message, sign inside Cake, verify signatures and
broadcast fixed bytes through the captured wallet connection. No Jupiter
execution endpoint or independent instruction-effect decoding is involved.

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

All four settings retain the saved provider toggles and centralized/decentralized
labels. Exchange comparison and fresh creation use the same preferences and
execution-shape eligibility. Native and token inputs can use enabled DEX routes
when Instaswap is disabled. Token calls with approval metadata require an already
sufficient allowance for the exact token/spender; the check runs after receiving
execution instructions and again during preparation. If insufficient or unknown,
creation stops without fallback or signing. Quotes cannot guarantee allowance
readiness when the spender is supplied only at creation.
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
settings and the expanded wallet execution. Rebuild to use these additions. ZEC
requires a build with Cake's Zcash backend enabled; the current local generated
facade is disabled and ZEC verification uses a mock. Funded swaps
require separate live validation.

## Broadcast and notification

The lifecycle persists a funding-started identity before commit and prevents a
second funding commit, including from separately prepared instances. ZEC's local
trade-keyed attempt marker is distinct from the network transaction ID: only the
real ID returned during commit is saved in `Trade.txId` and notified afterward.
ZEC refresh errors after a successful broadcast do not turn into another payment.
Solana IDs are derived from the first signature and compared case-sensitively;
other deposits use Cake's actual transaction IDs. Notification
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
rejects approval sequences, token calls with extra native value, unsupported
memos, private routes, hardware/UR, send-all and external funding.
THOR/Maya contract memo metadata and calldata are trusted and bound together.
Fixed-rate execution, independent contract-effect validation, creation recovery,
callback outbox/retry UI are deferred.

Approval-required swaps are the substantial blocker from this bounded expansion:
Cake exposes the primitives but has no reusable staged pending coordinator.
Approval/reset transactions need separate confirmations, persisted hashes,
receipt checks and fresh nonces before final funding. Approval hashes must not
be mistaken for swap source hashes. Failed/unknown creation or submission is
never automatically retried as a fresh payment.

Validation is offline: mocked HTTP, in-memory SQLite and synthetic test keys.
No real order creation, real-wallet signing, funding, broadcasting or native
backend build was performed for this increment.

Expanded verification with Flutter 3.41.9: **364 tests passed** across `test/exchange`,
`test/view_model/send_view_model_commit_test.dart` and
`test/new-ui/widgets/swap_page/pegaroute_providers_settings_test.dart`.
Coverage includes synthetic native transfers/calls on all five EVM networks,
ETH → USDC contract instructions, ERC20 deposits with 6/18 decimals, SQLite
restoration/callbacks, altered signed instructions, wallet/network switches,
supplied expiry, blocked approval-required calls, sufficient-allowance token calls,
all eight deposit wallet types, SPL mint/decimal persistence, ZEC post-ID/refresh
failures, truthful callback/status identities, supplied Solana legacy/v0 messages,
preference changes, route ranking and duplicate-commit prevention. Synthetic provider/network combinations exercise
plumbing without claiming live market availability. The local bridge is unchanged;
its earlier six mocked tests passed. No app rebuild was performed in this increment.
Targeted source/test analysis passed with no errors or warnings; existing
informational style lints remain. Protected-file checksums and `git diff --check` passed.

Flutter reports existing missing `assets/new-ui/` directories while preparing
the test bundle; the test suite completes successfully without asset changes.
