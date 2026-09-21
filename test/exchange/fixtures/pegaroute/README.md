# Pegaroute contract fixtures

Synthetic payloads, originally audited against Pegasus main
`74e2cd8d9dbb71f0b5cd29bd5193d0182346dd34` (2026-09-09).
Current contract target: `v0.5.3`.
Last compatibility review:
`177d6891aada4659ca9d24cf3de8cb336ce31442` (2026-09-14).
The version-reference update does not constitute a new fixture audit.
They are mocked codec inputs, not executable offers or live captures.

Authoritative sources: `src/server/openapi/schemas.ts`,
`src/server/swaps/{schemas,handlers,mappers,execution}.ts`,
`src/shared/private-mode.ts`, and `docs/integrators/` at the current baseline.

The previous baseline review checked the quote/create/status/hash contract changes and
the 102 mapped Cake asset identities. Existing status regressions cover canonical
OpenOcean asset identities, ticker-only rejection, and retained funding bindings;
the upstream fix adds no creation-attempt API or historical-record recovery.

- Private intent is query-only for both quote and swap. A swap JSON body
  property is invalid. Omitted/boolean false is public; true, `zk`, and other
  bounded provider-declared strings remain distinct. Cake rejects all enabled
  private execution, including a private request whose response says public.
- `subprovider` is optional information; selection uses `provider`. Build-time
  subprovider wins over quote-time metadata upstream. Cake still requires review
  when the selected route identity changes.
- `quote_private_zk.json` includes the per-provider warning trail. Success at
  HTTP level does not imply every provider quoted.
- Polling uses external status plus `internalStatus`; websocket status updates
  carry internal status and a reduced route. They are different payloads. Cake
  currently consumes polling only.
- `status_refund.json` intentionally has no observed refund details: Instaswap
  can report terminal refund without trustworthy transfer evidence.
- Configured `input.refundAddress` stays bound to the request; an observed
  `refund.refundAddress` can differ and is stored separately. Internal
  `submitted` maps to external `executing` on polling, not `pending`.
- The canonical catalog removed the wrapped-SOL mint entry. Native `SOL/SOL`
  remains eligible; Cake rejects the removed identity before quote transport.

Quote expiry is not a universal funding deadline, and quote consumption is not
idempotent creation. These fixtures establish no recovery or broadcast guarantee.
