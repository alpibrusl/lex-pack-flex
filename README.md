# lex-pack-flex

Flex domain pack — balancing-market flex tender/commit/settle lifecycle (buyer posts a shed request, a supply-side seller commits, delivery is verified and settled), each transition hash-chained.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #238](https://github.com/alpibrusl/lex-ev-fleet/issues/238)). No cross-pack dependency — energy-adjacent in origin, but generically a two-sided commitment/settlement pattern. An EMS backend is a runtime HTTP dependency (configured via `ems_url`, used to check delivery evidence), not a `lex.toml` dependency.

## Routes

```
POST /flex/tenders                — {tender_ref, buyer, kw, price_eur, window_start_ms, window_end_ms}
POST /flex/tenders/:ref/commit    — {seller, site_id}: accept an open tender
GET  /flex/tenders/:ref           — state (open/committed/settled) + the chained events
POST /flex/settlements            — {from_agent, to_agent, eur, ref[, tender_ref, site_id, window, kwh]}
```

## Usage

```lex
import "lex-pack-flex/flex" as flex

# in your router-wiring code:
let r := flex.mount(router.new(), db, ems_url)
```

`flex.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License


Copyright (c) 2026 lex-pack-flex contributors.

Licensed under the [EUPL-1.2](LICENSE) — the European Union Public Licence, as used across the `lex-*` ecosystem.

