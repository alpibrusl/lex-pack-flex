# lex-pack-flex

Flex domain pack — balancing-market flex tender/commit/settle lifecycle (buyer posts a shed request, a supply-side seller commits, delivery is verified and settled), each transition hash-chained.

> **Status: scaffold.** This pack is being extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) — see [https://github.com/alpibrusl/lex-ev-fleet/issues/238](https://github.com/alpibrusl/lex-ev-fleet/issues/238) for the extraction plan and what still needs to move here. No cross-pack dependency — can be extracted independently.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine) -> this pack (one vertical's routes + `pack.DomainPack`) -> [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.
