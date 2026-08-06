# flex_agent.lex — an LLM-driven agent persona that operates THIS pack's own
# REST service (flex.lex's /flex/* routes).
#
# Same loopback-HTTP pattern as lex-pack-construction/src/construction_agent.lex:
# flex has no external backend to wrap for its own agent tools (the EMS
# backend flex.mount() threads through is used internally by the settlement
# route's evidence check, not something the agent calls directly) — its
# mount() IS the domain logic, so the agent's tools call back into
# self_base_url + "/flex/...".

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn flex_capability() -> cap.Capability {
  cap.inbound("handle", "Operate a balancing-market flex tender: post tenders, commit a seller, check status, and record settlements once delivery is verified.", { title: "FlexOps", description: "Inbound message for the flex ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes, no external backend) ──────────
fn make_flex_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("post_tender", "Post a new flex tender: a buyer requests shed/flex capacity (kW) over a time window at a price. Returns the tender_ref to commit or track.", { title: "PostTender", description: "Tender posting.", fields: [sch.required_str("tender_ref", []), sch.required_str("buyer", []), sch.required_float("kw", []), sch.required_float("price_eur", []), sch.required_int("window_start_ms", []), sch.required_int("window_end_ms", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/flex/tenders"), jv.stringify(args), ""))
  }), t.define("commit_tender", "Accept an open tender on behalf of a seller, naming the site that will actuate it. Fails if the tender is unknown or already committed.", { title: "CommitTender", description: "Tender commit.", fields: [sch.required_str("tender_ref", []), sch.required_str("seller", []), sch.required_str("site_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/flex/tenders/", jstr(args, "tender_ref"), "/commit"], ""), jv.stringify(args), ""))
  }), t.define("get_tender_status", "Look up a tender's current state (open/committed/settled) and its event chain. Check this before deciding whether to commit or settle.", { title: "GetTenderStatus", description: "Tender lookup.", fields: [sch.required_str("tender_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(self_base_url, str.concat("/flex/tenders/", jstr(args, "tender_ref"))), ""))
  }), t.define("record_settlement", "Record a delivered flex window and move money buyer to seller. Pass tender_ref to close out a posted tender's loop (site_id/kwh/window enable the automatic delivery-evidence check), or omit tender_ref for a standalone settlement negotiated outside this tender flow.", { title: "RecordSettlement", description: "Settlement recording.", fields: [sch.required_str("from_agent", []), sch.required_str("to_agent", []), sch.required_str("ref", []), sch.required_float("eur", []), sch.optional(sch.required_str("tender_ref", [])), sch.optional(sch.required_str("site_id", [])), sch.optional(sch.required_float("kwh", [])), sch.optional(sch.required_str("window", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/flex/settlements"), jv.stringify(args), ""))
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn flex_system_prompt(id :: Str) -> Str {
  str.join(["You are flex ops agent ", id, ". You operate balancing-market flex tenders: a buyer posts a tender naming the kW, time window and price it needs shed; a seller commits a site to deliver it; once delivered, a settlement moves the money and closes the loop.", " Use post_tender to open a request, commit_tender to accept one on behalf of a seller, get_tender_status to check where a tender stands before acting, and record_settlement once delivery is confirmed -- pass tender_ref, site_id, kwh and window when settling against a posted tender so the automatic delivery-evidence check can run.", " Be precise about kW/kWh and EUR amounts and always name the specific tender_ref you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_flex_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := flex_capability()
  let cfg := { id: id, kind: "flex-ops", system_prompt: flex_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_flex_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Flex ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

