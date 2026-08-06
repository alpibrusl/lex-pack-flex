# tests/test_flex_agent.lex — pure-logic coverage for src/flex_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/flex_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(agent.make_flex_tools("http://127.0.0.1:8100"), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_four_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_flex_tools("http://127.0.0.1:8100")) == 4, "flex has exactly 4 REST routes today, so exactly 4 tools should be defined")
}

fn test_post_tender_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("tender_ref", JStr("T-100")), ("buyer", JStr("buyer-acme")), ("kw", JFloat(50.0)), ("price_eur", JFloat(0.3)), ("window_start_ms", JInt(1000)), ("window_end_ms", JInt(2000))])
  match schema_of("post_tender") {
    None => Err("post_tender tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("post_tender's schema must accept flex.lex's documented POST /flex/tenders body"),
      Ok(_) => pass(),
    },
  }
}

fn test_commit_tender_schema_requires_site_id() -> Result[Unit, Str] {
  let bad := JObj([("tender_ref", JStr("T-100")), ("seller", JStr("seller-1"))])
  match schema_of("commit_tender") {
    None => Err("commit_tender tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("commit_tender's schema must require site_id"),
    },
  }
}

fn test_get_tender_status_schema_requires_tender_ref() -> Result[Unit, Str] {
  match schema_of("get_tender_status") {
    None => Err("get_tender_status tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("get_tender_status's schema must require tender_ref"),
    },
  }
}

fn test_record_settlement_schema_accepts_without_tender_ref() -> Result[Unit, Str] {
  let sample := JObj([("from_agent", JStr("buyer-acme")), ("to_agent", JStr("seller-1")), ("ref", JStr("S-1")), ("eur", JFloat(15.0))])
  match schema_of("record_settlement") {
    None => Err("record_settlement tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("record_settlement's schema must accept a standalone settlement without tender_ref"),
      Ok(_) => pass(),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_four_tools_defined(), test_post_tender_schema_accepts_documented_shape(), test_commit_tender_schema_requires_site_id(), test_get_tender_status_schema_requires_tender_ref(), test_record_settlement_schema_accepts_without_tender_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}

