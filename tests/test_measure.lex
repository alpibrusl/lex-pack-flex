# lex-pack-flex — measure.lex tests.
#
# The behaviour that matters is what a settlement records, and whether the
# party being paid can still choose the number. Today it can: `kwh` comes from
# the request body. These cover the two states — unmeasured, where that is
# still true but is now stated on the record, and measured, where the computed
# volume wins and the claim is kept beside it as a claim.
#
# The network path (fetching readings from the EMS) is not exercised here;
# there is no EMS in a unit test. What is exercised is every decision made
# around it, including all the ways measurement legitimately does not happen.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.float" as float

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-baseline/src/method" as bmethod

import "../src/measure" as measure

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn fail(why :: Str) -> Result[Unit, Str] {
  Err(why)
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    fail(label)
  }
}

fn t0() -> Int {
  1000000000
}

fn hour() -> Int {
  3600000
}

fn a_spec() -> bmethod.Spec {
  { method: Nominated, interval_ms: 900000, version: 1 }
}

fn jbool(j :: jv.Json, k :: Str) -> Bool {
  match jv.get_field(j, k) {
    Some(JBool(b)) => b,
    _ => false,
  }
}

fn jstr(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# A measured result, built directly — `measure` itself needs a live EMS.
fn measured(delivered_wh :: Int) -> measure.Measurement {
  { measured: true, delivered_wh: delivered_wh, baseline_w: 22000, actual_w: 7000, intervals: 4, fingerprint: "abc123", label: "nominated baseline", note: "" }
}

# ---- The settled figure ------------------------------------------------
#
# The change that matters: when a window is measured, the computed volume is
# what settles, and the seller's figure stops being the input.
fn test_a_measured_window_settles_on_the_computed_volume() -> Result[Unit, Str] {
  assert_true(measure.settled_kwh(measured(15000), 99.0) == 15.0, "a measured settlement uses the computed 15kWh, not the 99kWh claimed")
}

fn test_an_unmeasured_window_still_uses_the_declared_figure() -> Result[Unit, Str] {
  assert_true(measure.settled_kwh(measure.unmeasured("no method"), 12.5) == 12.5, "with no method configured, the declared figure is used exactly as before")
}

# ---- The record says which it was --------------------------------------
#
# A reader must be able to tell a measured settlement from an unmeasured one
# without inferring it from a missing field.
fn test_an_unmeasured_settlement_says_so_and_says_why() -> Result[Unit, Str] {
  let j := measure.to_json(measure.unmeasured("the EMS returned no meter readings for this site"))
  assert_true(not jbool(j, "measured") and jstr(j, "method") == "unmeasured" and str.contains(jstr(j, "reason"), "no meter readings"), "an unmeasured settlement records that it was unmeasured, with the reason")
}

fn test_a_measured_settlement_carries_the_method_fingerprint() -> Result[Unit, Str] {
  let j := measure.to_json(measured(15000))
  assert_true(jbool(j, "measured") and jstr(j, "method_fingerprint") == "abc123" and jstr(j, "method") == "nominated baseline", "a measured settlement names the method and carries its fingerprint, so the method cannot be chosen afterwards")
}

fn test_the_counterfactual_is_recorded_not_just_the_difference() -> Result[Unit, Str] {
  let j := measure.to_json(measured(15000))
  match jv.get_field(j, "baseline_w") {
    Some(JInt(b)) => assert_true(b == 22000, "the baseline is recorded, so a counterparty can check the counterfactual and not only the volume it produced"),
    _ => fail("a measured settlement should record the baseline it used"),
  }
}

# ---- Over-claiming is recorded, not policed ----------------------------
#
# A threshold belongs in a contract. The number belongs on the record, because
# it is what makes a pattern visible.
fn test_a_claim_above_the_measured_volume_is_quantified() -> Result[Unit, Str] {
  assert_true(measure.overclaim_pct(measured(10000), 15.0) == 50, "claiming 15kWh against a measured 10kWh records a 50% over-claim")
}

fn test_an_honest_claim_records_no_overclaim() -> Result[Unit, Str] {
  assert_true(measure.overclaim_pct(measured(10000), 10.0) == 0, "a claim matching the measurement records no over-claim")
}

fn test_an_understated_claim_reads_negative() -> Result[Unit, Str] {
  assert_true(measure.overclaim_pct(measured(10000), 5.0) < 0, "claiming less than was delivered is visible too, rather than clamped away")
}

fn test_overclaim_is_not_computed_for_an_unmeasured_window() -> Result[Unit, Str] {
  assert_true(measure.overclaim_pct(measure.unmeasured("no method"), 99.0) == 0, "with nothing to compare against, no over-claim is asserted")
}

# A zero-delivery window has no denominator; reporting a percentage against it
# would be arithmetic theatre.
fn test_a_zero_delivery_window_reports_no_percentage() -> Result[Unit, Str] {
  assert_true(measure.overclaim_pct(measured(0), 10.0) == 0, "a window that delivered nothing yields no over-claim percentage rather than a division by zero")
}

# ---- Measurement declines cleanly --------------------------------------
#
# Every way measurement legitimately does not happen must produce an unmeasured
# result with a reason, never a silent zero that looks like a real measurement
# of nothing.
fn test_no_method_configured_is_unmeasured_with_a_reason() -> [net, crypto] Result[Unit, Str] {
  let m := measure.measure(None, "http://ems", "site-1", t0(), t0() + hour(), 22000)
  assert_true(not m.measured and str.contains(m.note, "no baseline method"), "a deployment with no method configured is unmeasured, and says why")
}

fn test_no_site_is_unmeasured_with_a_reason() -> [net, crypto] Result[Unit, Str] {
  let m := measure.measure(Some(a_spec()), "http://ems", "", t0(), t0() + hour(), 22000)
  assert_true(not m.measured and str.contains(m.note, "no site"), "a settlement with no site to measure against is unmeasured, and says why")
}

fn test_a_tender_with_no_window_is_unmeasured_with_a_reason() -> [net, crypto] Result[Unit, Str] {
  let m := measure.measure(Some(a_spec()), "http://ems", "site-1", 0, 0, 22000)
  assert_true(not m.measured and str.contains(m.note, "no settleable window"), "a tender carrying no window cannot be measured, and says why")
}

# ---- Suite -------------------------------------------------------------
#
# `lex test` calls `run_all` and DISCARDS what it returns (lex-lang#757), so a
# returned failure count reports `ok` however many assertions failed. This
# prints each failure by name and then raises.
fn results() -> [net, crypto] List[(Str, Result[Unit, Str])] {
  [("a_measured_window_settles_on_the_computed_volume", test_a_measured_window_settles_on_the_computed_volume()), ("an_unmeasured_window_still_uses_the_declared_figure", test_an_unmeasured_window_still_uses_the_declared_figure()), ("an_unmeasured_settlement_says_so_and_says_why", test_an_unmeasured_settlement_says_so_and_says_why()), ("a_measured_settlement_carries_the_method_fingerprint", test_a_measured_settlement_carries_the_method_fingerprint()), ("the_counterfactual_is_recorded_not_just_the_difference", test_the_counterfactual_is_recorded_not_just_the_difference()), ("a_claim_above_the_measured_volume_is_quantified", test_a_claim_above_the_measured_volume_is_quantified()), ("an_honest_claim_records_no_overclaim", test_an_honest_claim_records_no_overclaim()), ("an_understated_claim_reads_negative", test_an_understated_claim_reads_negative()), ("overclaim_is_not_computed_for_an_unmeasured_window", test_overclaim_is_not_computed_for_an_unmeasured_window()), ("a_zero_delivery_window_reports_no_percentage", test_a_zero_delivery_window_reports_no_percentage()), ("no_method_configured_is_unmeasured_with_a_reason", test_no_method_configured_is_unmeasured_with_a_reason()), ("no_site_is_unmeasured_with_a_reason", test_no_site_is_unmeasured_with_a_reason()), ("a_tender_with_no_window_is_unmeasured_with_a_reason", test_a_tender_with_no_window_is_unmeasured_with_a_reason())]
}

fn report(rs :: List[(Str, Result[Unit, Str])]) -> [io] Int {
  list.fold(rs, 0, fn (n :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => n,
      (name, Err(why)) => {
        let __p := io.print(str.concat("FAIL ", str.concat(name, str.concat(" — ", why))))
        n + 1
      },
    }
  })
}

# The stdlib is total — there is no `panic` — so a division by zero is the
# raise. `zero` arrives as an argument so it survives constant folding.
fn raise_failure(zero :: Int) -> Int {
  1 / zero
}

fn run_all() -> [io, net, crypto] Unit {
  let failures := report(results())
  if failures == 0 {
    ()
  } else {
    let __p := io.print(str.concat(int.to_str(failures), " test(s) failed"))
    let __boom := raise_failure(0)
    ()
  }
}

