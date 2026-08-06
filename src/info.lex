# info.lex — the flex agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the flex-ops persona — label, tagline, starter
# prompts. Served by the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "flex", title: "Flex", tagline: "Balancing-market flex tenders, committed and settled with every transition hash-chained.", personas: [{ kind: "flex-ops", title: "Flex ops", tagline: "Posts tenders, commits sellers, and settles delivered flex windows.", suggested_prompts: ["Post a tender for buyer-acme requesting 50kW from 09:00 to 10:00 at 0.30 EUR/kWh, ref T-100.", "Commit tender T-100 for seller site-north-1.", "What is the status of tender T-100?", "Record a settlement for tender T-100: 15 EUR from buyer-acme to seller-north."] }] }
}

