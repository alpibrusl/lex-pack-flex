# flex.lex — flex tender lifecycle + settlement (energy pack, #122).
#
# The full auditable flex lifecycle, each step a hash-chained event on the
# settlement trail — balancing-market + CSRD-grade:
#
#   TENDER   a buyer (DSO / aggregator) posts "shed X kW in window W at price P"
#   COMMIT   a supply-side seller (site-ems, charging fleet) accepts it, naming
#            the site it will actuate — a tender takes exactly one commitment
#   SETTLE   once delivery is verified from telemetry, money moves buyer -> seller
#
# A tender walks open -> committed -> settled; each transition is refused unless
# the prior state holds (you cannot commit a committed tender, nor settle an
# uncommitted one). The tender/commit/settle events are parent-chained, so the
# whole negotiation replays and re-verifies.
#
# POST /flex/settlements records a delivered flexibility window as an L1
# chargeback on the settlement trail (metered exchange between two agents —
# aggregates in /usage) plus a flex.delivered event whose payload carries
# agent/from_agent so the tenant's audit slice sees it. Passing a tender_ref
# closes that tender's loop (requires it committed, marks it settled); omitting
# one keeps the standalone settlement path for externally-negotiated deals.
#
#   POST /flex/tenders                — {tender_ref, buyer, kw, price_eur, window_start_ms, window_end_ms}
#   POST /flex/tenders/:ref/commit    — {seller, site_id}: accept an open tender
#   GET  /flex/tenders/:ref           — state (open/committed/settled) + the chained events
#   POST /flex/settlements            — {from_agent, to_agent, eur, ref[, tender_ref, site_id, window, kwh]}

import "std.str" as str

import "std.list" as list

import "std.float" as float

import "std.int" as int

import "std.time" as time

import "std.sql" as sql

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "lex-money/src/money" as money

import "lex-money/src/currency" as mcur

import "lex-money/src/rounding" as mround

import "lex-soft/src/positions" as pos

fn jstr(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(v)) => v,
    _ => "",
  }
}

# The amount as the caller WROTE it: a JSON string passes through untouched;
# a JSON number is rendered once (the caller already chose float precision).
fn jdec(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(s)) => str.trim(s),
    Some(JFloat(v)) => float.to_str(v),
    Some(JInt(n)) => int.to_str(n),
    _ => "",
  }
}

fn jnum(j :: jv.Json, k :: Str) -> Float {
  match jv.get_field(j, k) {
    Some(JFloat(v)) => v,
    Some(JInt(n)) => int.to_float(n),
    _ => 0.0,
  }
}

# Delivery evidence: the seller names the site it actuated; we re-check the
# EMS event log for limit_updated entries before money moves. No events =
# no actuation = no settlement (409). Sites are only checkable when the host
# gave us an EMS backend; a settlement without site_id records evidence "none"
# (back-compat for externally-evidenced deals).
# The metered truth, when the EMS module records it (lex-ems#11): newest site
# meter reading appended to the evidence detail. Absent meter data changes
# nothing — the actuation event remains the gate.
fn metered_suffix(ems_url :: Str, site_id :: Str) -> [net] Str {
  let url := str.concat(ems_url, str.concat("/api/v1/sites/", str.concat(site_id, "/meter")))
  match http.get(url) {
    Err(_) => "",
    Ok(res) => {
      let body_s := match bytes.to_str(res.body) {
        Ok(s) => s,
        Err(_) => "",
      }
      match jv.parse(body_s) {
        Ok(JList(items)) => match list.head(items) {
          None => "",
          Some(reading) => match jv.get_field(reading, "kw") {
            Some(JFloat(v)) => str.concat(" metered_kw=", float.to_str(v)),
            Some(JInt(n)) => str.concat(" metered_kw=", int.to_str(n)),
            _ => "",
          },
        },
        _ => "",
      }
    },
  }
}

fn delivery_evidence(ems_url :: Str, site_id :: Str) -> [net] Option[Str] {
  let url := str.concat(ems_url, str.concat("/api/v1/sites/", str.concat(site_id, "/events")))
  match http.get(url) {
    Err(_) => None,
    Ok(res) => {
      let body_s := match bytes.to_str(res.body) {
        Ok(s) => s,
        Err(_) => "",
      }
      match jv.parse(body_s) {
        Ok(JList(items)) => {
          let hits := list.filter(items, fn (it :: jv.Json) -> Bool {
            str.cmp(jstr(it, "event_type"), "limit_updated") == 0
          })
          match list.head(hits) {
            None => None,
            Some(ev) => Some(str.concat(jstr(ev, "detail"), metered_suffix(ems_url, site_id))),
          }
        },
        _ => None,
      }
    },
  }
}

fn row_str(row :: sql.Row, k :: Str) -> Str {
  match sql.get_str(row, k) {
    Some(v) => v,
    None => "",
  }
}

fn row_float(row :: sql.Row, k :: Str) -> Float {
  match sql.get_float(row, k) {
    Some(v) => v,
    None => 0.0,
  }
}

fn row_int(row :: sql.Row, k :: Str) -> Int {
  match sql.get_int(row, k) {
    Some(v) => v,
    None => 0,
  }
}

# Portable DDL (SQLite + Postgres): TEXT / DOUBLE PRECISION / BIGINT only.
# NOT REAL: lex's Postgres driver binds PFloat as Rust f64 (float8), which
# tokio-postgres refuses to serialize against a REAL (float4) column — see
# reference_lex_postgres memory. The ALTER below widens an already-deployed
# table in place (no-op on SQLite; no-op on Postgres once already widened).
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __t := sql.exec(db, "CREATE TABLE IF NOT EXISTS flex_tenders (tender_ref TEXT PRIMARY KEY, buyer TEXT NOT NULL, kw DOUBLE PRECISION NOT NULL DEFAULT 0, price_eur_dec TEXT NOT NULL DEFAULT '', window_start_ms BIGINT NOT NULL DEFAULT 0, window_end_ms BIGINT NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'open', seller TEXT NOT NULL DEFAULT '', site_id TEXT NOT NULL DEFAULT '', committed_ms BIGINT NOT NULL DEFAULT 0, settled_ref TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL)", [])
  let __kw := sql.exec(db, "ALTER TABLE flex_tenders ALTER COLUMN kw TYPE DOUBLE PRECISION", [])
  ()
}

type Tender = { buyer :: Str, kw :: Float, price_eur_dec :: Str, window_start_ms :: Int, window_end_ms :: Int, status :: Str, seller :: Str, site_id :: Str }

fn tender_for(db :: Db, ref :: Str) -> [sql] Option[Tender] {
  match sql.query(db, "SELECT buyer, kw, price_eur_dec, window_start_ms, window_end_ms, status, seller, site_id FROM flex_tenders WHERE tender_ref = ?", [PStr(ref)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ buyer: row_str(row, "buyer"), kw: row_float(row, "kw"), price_eur_dec: row_str(row, "price_eur_dec"), window_start_ms: row_int(row, "window_start_ms"), window_end_ms: row_int(row, "window_end_ms"), status: row_str(row, "status"), seller: row_str(row, "seller"), site_id: row_str(row, "site_id") }),
    },
  }
}

# The tender's own event chain — tender, commit, settle — keyed by tender_ref.
fn tender_events(db :: Db, ref :: Str) -> [sql] List[jv.Json] {
  let pat := str.concat("%\"tender_ref\":", str.concat(jv.stringify(JStr(ref)), "%"))
  match sql.query(db, "SELECT id, kind, ts_ms FROM events WHERE kind LIKE 'flex.%' AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(pat)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, fn (row :: sql.Row) -> jv.Json {
      JObj([("event_id", JStr(row_str(row, "id"))), ("kind", JStr(row_str(row, "kind"))), ("ts_ms", JInt(row_int(row, "ts_ms")))])
    }),
  }
}

fn tender_json(ref :: Str, t :: Tender, events :: List[jv.Json]) -> jv.Json {
  JObj([("tender_ref", JStr(ref)), ("buyer", JStr(t.buyer)), ("kw", JFloat(t.kw)), ("price_eur_dec", JStr(t.price_eur_dec)), ("window_start_ms", JInt(t.window_start_ms)), ("window_end_ms", JInt(t.window_end_ms)), ("status", JStr(t.status)), ("seller", JStr(t.seller)), ("site_id", JStr(t.site_id)), ("events", JList(events))])
}

fn mount(r :: router.Router, db :: Db, ems_url :: Str) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_tender := router.route_effectful(r, "POST", "/flex/tenders", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let tref := jstr(j, "tender_ref")
        let buyer := jstr(j, "buyer")
        let kw := jnum(j, "kw")
        let price_m := money.parse(jdec(j, "price_eur"), Eur, HalfUp(()))
        if str.is_empty(tref) or str.is_empty(buyer) or kw <= 0.0 {
          resp.bad_request("{\"error\":\"tender_ref, buyer and a kw > 0 are required\"}")
        } else {
          match price_m {
            None => resp.bad_request("{\"error\":\"price_eur must be a decimal amount\"}"),
            Some(pm) => {
              let price_dec := money.format(pm)
              let ws := float.to_int(jnum(j, "window_start_ms"))
              let we := float.to_int(jnum(j, "window_end_ms"))
              let stmt := "INSERT INTO flex_tenders (tender_ref, buyer, kw, price_eur_dec, window_start_ms, window_end_ms, status, created_ms) VALUES (?, ?, ?, ?, ?, ?, 'open', ?) ON CONFLICT (tender_ref) DO NOTHING"
              match sql.exec(db, stmt, [PStr(tref), PStr(buyer), PFloat(kw), PStr(price_dec), PInt(ws), PInt(we), PInt(time.now_ms())]) {
                Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
                Ok(_) => {
                  let log := settlement.trail_on(db)
                  let payload := jv.stringify(JObj([("tender_ref", JStr(tref)), ("buyer", JStr(buyer)), ("kw", JFloat(kw)), ("price_eur_dec", JStr(price_dec)), ("window_start_ms", JInt(ws)), ("window_end_ms", JInt(we))]))
                  let __e := tlog.append(log, "flex.tender", None, payload)
                  resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("tender_ref", JStr(tref)), ("buyer", JStr(buyer)), ("kw", JFloat(kw)), ("price_eur_dec", JStr(price_dec)), ("status", JStr("open"))])))
                },
              }
            },
          }
        }
      },
    }
  })
  let with_commit := router.route_effectful(with_tender, "POST", "/flex/tenders/:ref/commit", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let tref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let seller := jstr(j, "seller")
        let site_id := jstr(j, "site_id")
        if str.is_empty(seller) {
          resp.bad_request("{\"error\":\"seller is required\"}")
        } else {
          match tender_for(db, tref) {
            None => resp.json_status(404, "{\"error\":\"unknown tender\"}"),
            Some(t) => if str.cmp(t.status, "open") != 0 {
              resp.json_status(409, str.concat("{\"error\":\"tender is not open (status: ", str.concat(t.status, "), a tender takes exactly one commitment\"}")))
            } else {
              match sql.exec(db, "UPDATE flex_tenders SET status = 'committed', seller = ?, site_id = ?, committed_ms = ? WHERE tender_ref = ? AND status = 'open'", [PStr(seller), PStr(site_id), PInt(time.now_ms()), PStr(tref)]) {
                Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
                Ok(n) => if n == 0 {
                  resp.json_status(409, "{\"error\":\"tender was committed concurrently\"}")
                } else {
                  let log := settlement.trail_on(db)
                  let payload := jv.stringify(JObj([("tender_ref", JStr(tref)), ("buyer", JStr(t.buyer)), ("seller", JStr(seller)), ("site_id", JStr(site_id)), ("kw", JFloat(t.kw)), ("price_eur_dec", JStr(t.price_eur_dec))]))
                  let __e := tlog.append(log, "flex.committed", None, payload)
                  resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("tender_ref", JStr(tref)), ("seller", JStr(seller)), ("site_id", JStr(site_id)), ("status", JStr("committed"))])))
                },
              }
            },
          }
        }
      },
    }
  })
  let with_get := router.route_effectful(with_commit, "GET", "/flex/tenders/:ref", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let tref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match tender_for(db, tref) {
      None => resp.json_status(404, "{\"error\":\"unknown tender\"}"),
      Some(t) => resp.json(jv.stringify(tender_json(tref, t, tender_events(db, tref)))),
    }
  })
  router.route_effectful(with_get, "POST", "/flex/settlements", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let from_agent := jstr(j, "from_agent")
        let to_agent := jstr(j, "to_agent")
        let ref := jstr(j, "ref")
        let tender_ref := jstr(j, "tender_ref")
        let eur := jnum(j, "eur")
        let eur_m := money.parse(jdec(j, "eur"), Eur, HalfUp(()))
        let tender_status := if str.is_empty(tender_ref) {
          "committed"
        } else {
          match tender_for(db, tender_ref) {
            Some(t) => t.status,
            None => "missing",
          }
        }
        if str.is_empty(from_agent) or str.is_empty(to_agent) or str.is_empty(ref) {
          resp.bad_request("{\"error\":\"from_agent, to_agent and a unique ref are required\"}")
        } else {
          if str.cmp(tender_status, "committed") != 0 {
            resp.json_status(409, str.concat("{\"error\":\"tender not settleable (status: ", str.concat(tender_status, "): a flex tender must be committed before it settles\"}")))
          } else {
            match eur_m {
              None => resp.bad_request("{\"error\":\"eur must be a decimal amount\"}"),
              Some(eur_money) => {
                let eur_dec := money.format(eur_money)
                let site_id := jstr(j, "site_id")
                let evidence := if str.is_empty(site_id) or str.is_empty(ems_url) {
                  Some("none")
                } else {
                  delivery_evidence(ems_url, site_id)
                }
                match evidence {
                  None => resp.json_status(409, "{\"error\":\"no delivery evidence: the EMS event log has no limit_updated entries for this site\"}"),
                  Some(ev_detail) => {
                    let log := settlement.trail_on(db)
                    match settlement.record_chargeback_dec(log, from_agent, to_agent, eur_dec, "EUR", ref) {
                      Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                      Ok(cb_id) => {
                        let payload := jv.stringify(JObj([("agent", JStr(to_agent)), ("from_agent", JStr(from_agent)), ("to_agent", JStr(to_agent)), ("kwh", JFloat(jnum(j, "kwh"))), ("eur", JFloat(eur)), ("eur_dec", JStr(eur_dec)), ("window", JStr(jstr(j, "window"))), ("ref", JStr(ref)), ("tender_ref", JStr(tender_ref)), ("site_id", JStr(site_id)), ("evidence", JStr(ev_detail)), ("chargeback", JStr(cb_id))]))
                        let ev := tlog.append(log, "flex.delivered", None, payload)
                        match ev {
                          Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                          Ok(x) => {
                            let __s := if str.is_empty(tender_ref) {
                              0
                            } else {
                              match sql.exec(db, "UPDATE flex_tenders SET status = 'settled', settled_ref = ? WHERE tender_ref = ? AND status = 'committed'", [PStr(ref), PStr(tender_ref)]) {
                                Err(_) => 0,
                                Ok(n) => n,
                              }
                            }
                            resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("chargeback", JStr(cb_id)), ("event_id", JStr(x.id)), ("ref", JStr(ref)), ("tender_ref", JStr(tender_ref)), ("eur_dec", JStr(eur_dec)), ("evidence", JStr(ev_detail))])))
                          },
                        }
                      },
                    }
                  },
                }
              },
            }
          }
        }
      },
    }
  })
}

# The domain vocabulary this pack speaks, in the engine's position words
# (lex-soft/src/positions). No custody chain here — the subject is a commitment,
# not a thing that changes hands, so custody_ref_field is empty.
fn manifest() -> pos.PackManifest {
  { id: "flex", title: "Flexibility", tagline: "Offered capacity is tendered, committed, then delivered against metered evidence.", pattern: "capacity_tender", subject: "tender", subject_ref_field: "tender_ref", custody_ref_field: "", parties: [{ position: "originator", name: "buyer", title: "Buyer — tenders for capacity in a window", field: "buyer", required: true }, { position: "executor", name: "seller", title: "Seller — commits capacity and delivers it", field: "seller", required: true }, { position: "attestor", name: "meter", title: "Meter — the site feed the delivery evidence is read from", field: "site_id", required: false }], relationships: [{ from: "buyer", to: "seller", role: "contracted", label: "capacity is tendered and committed for a window" }, { from: "meter", to: "seller", role: "reporting", label: "metered delivery evidence closes the tender" }], event_kinds: ["flex.tender", "flex.committed", "flex.delivered"], evidence_kinds: ["meter_reading", "ems_event"], settles: true, route_prefix: "/flex" }
}

