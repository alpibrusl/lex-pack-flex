# measure.lex — settle on a measured volume rather than a declared one.
#
# Today a settlement takes `kwh` from the request body. The party being paid
# states how much it delivered, and the only check is that the EMS logged a
# `limit_updated` event for the site — proof that something was actuated, not
# proof of how much. That is an actuation check standing in for a volume.
#
# This computes the volume instead, through lex-baseline: the site's metered
# readings over the tender's own window, against a named method whose
# fingerprint is recorded beside the number. A counterparty re-running the same
# method on the same readings gets the same figure, so a disagreement is about
# the method or the data rather than about who did the arithmetic.
#
# ---- What this does NOT establish -------------------------------------
#
# The baseline is still a model. lex-baseline says so at length and so does
# this: measuring makes the claim checkable and replayable, not true. The gain
# over a declared figure is real but bounded — nobody has to take the seller's
# word, and the method cannot be chosen after the fact.
#
# ---- Rollout ----------------------------------------------------------
#
# A deployment with no method configured settles exactly as before, and the
# settlement records that it was unmeasured rather than silently implying it
# was measured. Configuring a method is what turns measurement on.
#
# ---- One honest caveat about the readings ------------------------------
#
# lex-ems stores meter readings with a timestamp but no guaranteed interval.
# The computation takes window means, so irregular sampling degrades accuracy
# rather than breaking the result — but a site sampled erratically produces a
# baseline to match, and `interval_ms` in the spec is a statement of intent, not
# something this can enforce. A deployment that settles real money on the
# measured path wants a regular series first.

import "std.str" as str

import "std.int" as int

import "std.float" as float

import "std.list" as list

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-baseline/src/method" as bmethod

import "lex-baseline/src/compute" as bcompute

# What a settlement records about how its volume was arrived at. `fingerprint`
# empty means unmeasured — the seller's declared figure was used.
type Measurement = { measured :: Bool, delivered_wh :: Int, baseline_w :: Int, actual_w :: Int, intervals :: Int, fingerprint :: Str, label :: Str, note :: Str }

fn unmeasured(note :: Str) -> Measurement {
  { measured: false, delivered_wh: 0, baseline_w: 0, actual_w: 0, intervals: 0, fingerprint: "", label: "unmeasured", note: note }
}

fn jstr(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(s)) => s,
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

# The EMS reports site power in kW; lex-baseline works in whole watts.
fn to_reading(j :: jv.Json) -> bmethod.Reading {
  { ts_ms: float.to_int(jnum(j, "ts_ms")), w: float.to_int(jnum(j, "kw") * 1000.0) }
}

# Pull the site's metered readings. A site with no readings is not an error
# here — it becomes a refusal to settle a measured volume, which the caller
# reports with a reason.
fn fetch_readings(ems_url :: Str, site_id :: Str) -> [net] List[bmethod.Reading] {
  let url := str.concat(ems_url, str.concat("/api/v1/sites/", str.concat(site_id, "/meter")))
  match http.get(url) {
    Err(_) => [],
    Ok(res) => match bytes.to_str(res.body) {
      Err(_) => [],
      Ok(body) => match jv.parse(body) {
        Ok(JList(items)) => list.map(items, to_reading),
        _ => [],
      },
    },
  }
}

# Measure a window.
#
# `nominated_w` is what the controller declared it would otherwise have drawn;
# it is used only by the Nominated method and ignored by a measured one, which
# is the point of offering both.
fn measure(spec_opt :: Option[bmethod.Spec], ems_url :: Str, site_id :: Str, from_ms :: Int, to_ms :: Int, nominated_w :: Int) -> [net, crypto] Measurement {
  match spec_opt {
    None => unmeasured("no baseline method configured for this deployment"),
    Some(spec) => if str.is_empty(ems_url) or str.is_empty(site_id) {
      unmeasured("no site or EMS to measure against")
    } else {
      if to_ms <= from_ms {
        unmeasured("the tender has no settleable window")
      } else {
        let readings := fetch_readings(ems_url, site_id)
        if list.is_empty(readings) {
          unmeasured("the EMS returned no meter readings for this site")
        } else {
          match bcompute.deliver(spec, from_ms, to_ms, readings, nominated_w, [], []) {
            Err(why) => unmeasured(why),
            Ok(d) => { measured: true, delivered_wh: d.delivered_wh, baseline_w: d.baseline_w, actual_w: d.actual_w, intervals: d.intervals, fingerprint: bmethod.fingerprint(spec), label: bmethod.label(spec), note: "" },
          }
        }
      }
    },
  }
}

# The measurement as it lands on the settlement event. Always present, so a
# reader can tell an unmeasured settlement from a measured one instead of
# inferring it from a missing field.
fn to_json(m :: Measurement) -> jv.Json {
  if m.measured {
    JObj([("measured", JBool(true)), ("delivered_wh", JInt(m.delivered_wh)), ("baseline_w", JInt(m.baseline_w)), ("actual_w", JInt(m.actual_w)), ("intervals", JInt(m.intervals)), ("method", JStr(m.label)), ("method_fingerprint", JStr(m.fingerprint))])
  } else {
    JObj([("measured", JBool(false)), ("method", JStr("unmeasured")), ("reason", JStr(m.note))])
  }
}

# kWh for the settlement record. A measured window reports what was computed;
# an unmeasured one falls back to the declared figure, which is what today's
# settlements already use.
fn settled_kwh(m :: Measurement, declared_kwh :: Float) -> Float {
  if m.measured {
    int.to_float(m.delivered_wh) / 1000.0
  } else {
    declared_kwh
  }
}

# How far the declared figure was from the measured one, as a percentage of the
# measured volume. Recorded rather than enforced: a threshold belongs in a
# contract, not in a library, and the number is what makes a pattern of
# over-claiming visible.
fn overclaim_pct(m :: Measurement, declared_kwh :: Float) -> Int {
  if not m.measured or m.delivered_wh <= 0 {
    0
  } else {
    let measured_kwh := int.to_float(m.delivered_wh) / 1000.0
    float.to_int((declared_kwh - measured_kwh) * 100.0 / measured_kwh)
  }
}

