# tests/test_flex.lex — pure-logic coverage for src/flex.lex.
#
# jdec is the one pure, non-trivial function here (a caller-written decimal
# amount must pass through unrounded); the effectful routes (tender, commit,
# settle, EMS evidence lookup) need a live DB + EMS backend to exercise
# meaningfully — that's covered by lex-ev-fleet's own integration testing of
# the mounted deployment.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-soft/src/positions" as pos

import "../src/flex" as flex

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

# ---- jdec -----------------------------------------------------------------
fn test_jdec_string_passes_through() -> Result[Unit, Str] {
  let j := JObj([("price_eur", JStr("12.345"))])
  assert_true(flex.jdec(j, "price_eur") == "12.345", "a JStr amount must pass through untouched, no float rounding")
}

fn test_jdec_missing_field_is_empty() -> Result[Unit, Str] {
  let j := JObj([])
  assert_true(flex.jdec(j, "price_eur") == "", "jdec must default to empty string for a missing field")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := flex.manifest()
  assert_true(list.is_empty(pos.validate(m)), "flex's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(flex.manifest().route_prefix == "/flex", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_settles() -> Result[Unit, Str] {
  assert_true(flex.manifest().settles, "a delivered flex settlement moves money, so the manifest must declare settles: true")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_jdec_string_passes_through(), test_jdec_missing_field_is_empty(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_settles()]
}

