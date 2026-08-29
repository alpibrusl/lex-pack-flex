# lex-pack-flex — the settlement's link to what it settles.
#
# A flex settlement used to be appended to the trail with `None` as its
# parent. The money was on the trail, the tender it settled was on the trail,
# and nothing joined them — so the one question this pack exists to answer,
# "walk from a payment back to the evidence it was computed from", could not be
# answered from its own data.
#
# `parent_ref` is what carries that link. The two cases below are the ones that
# matter: a tender whose trail event is known must produce a parent, and every
# case where it is not known must produce a ROOT rather than a pointer to the
# empty id — an orphan is recoverable, a link to nothing corrupts the walk.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-orm/connection" as conn

import "../src/flex" as flex

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

fn with_db(f :: (Db) -> [sql, fs_write] Result[Unit, Str]) -> [sql, fs_write] Result[Unit, Str] {
  match conn.connect_sqlite(":memory:") {
    Err(_) => Err("could not open an in-memory database"),
    Ok(dbc) => {
      let __t := flex.ensure_tables(dbc.handle)
      f(dbc.handle)
    },
  }
}

fn test_a_known_trail_event_becomes_the_parent() -> [sql, fs_write] Result[Unit, Str] {
  with_db(fn (db :: Db) -> [sql, fs_write] Result[Unit, Str] {
    let __i := sql.exec(db, "INSERT INTO flex_tenders (tender_ref, buyer, status, trail_ref, created_ms) VALUES (?, ?, 'open', ?, 0)", [PStr("T-1"), PStr("b"), PStr("event-abc")])
    match flex.parent_ref(db, "T-1") {
      None => Err("a tender with a recorded trail event must hand back that event as the parent"),
      Some(p) => assert_true(p == "event-abc", str.concat("the parent is the recorded event id, got ", p)),
    }
  })
}

# Three ways there is no link, and all three must be a root rather than a
# parent pointing at "". A tender predating the trail_ref column is the one
# that will actually happen in a running deployment.
fn test_every_absent_link_is_a_root() -> [sql, fs_write] Result[Unit, Str] {
  with_db(fn (db :: Db) -> [sql, fs_write] Result[Unit, Str] {
    let __i := sql.exec(db, "INSERT INTO flex_tenders (tender_ref, buyer, status, trail_ref, created_ms) VALUES (?, ?, 'open', '', 0)", [PStr("T-old"), PStr("b")])
    let predates := match flex.parent_ref(db, "T-old") {
      None => true,
      Some(_) => false,
    }
    let unknown := match flex.parent_ref(db, "T-nope") {
      None => true,
      Some(_) => false,
    }
    let blank := match flex.parent_ref(db, "") {
      None => true,
      Some(_) => false,
    }
    assert_true(predates and unknown and blank, "a tender predating trail_ref, an unknown tender and a blank ref must all produce a root event, never a parent link to the empty id")
  })
}

fn results() -> [sql, fs_write] List[(Str, Result[Unit, Str])] {
  [("a_known_trail_event_becomes_the_parent", test_a_known_trail_event_becomes_the_parent()), ("every_absent_link_is_a_root", test_every_absent_link_is_a_root())]
}

fn report(rs :: List[(Str, Result[Unit, Str])]) -> [io] Int {
  list.fold(rs, 0, fn (n :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (_, Ok(_)) => n,
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

fn run_all() -> [io, sql, fs_write] Unit {
  let failures := report(results())
  if failures == 0 {
    ()
  } else {
    let __p := io.print(str.concat(int.to_str(failures), " test(s) failed"))
    let __boom := raise_failure(0)
    ()
  }
}

