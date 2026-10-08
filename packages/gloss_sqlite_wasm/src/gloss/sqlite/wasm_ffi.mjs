import sqlite3InitModule from "@sqlite.org/sqlite-wasm";
import { Ok, Error as GError, BitArray, toList } from "../../gleam.mjs";
import {
  Null,
  Integer,
  Real,
  Text,
  Blob,
} from "../../../gloss_sql/gloss/sql/internal/sqlite.mjs";

let loaded;

// The WebAssembly module, loaded once.
function sqlite3() {
  loaded ??= sqlite3InitModule({ print: () => {}, printErr: () => {} });
  return loaded;
}

let pools = new Map();

// The OPFS "SAH pool" VFS, which persists without special HTTP headers but
// only works in a Web Worker.
async function opfs(s, directory) {
  if (typeof s.installOpfsSAHPoolVfs !== "function") {
    throw new globalThis.Error(
      "OPFS storage needs a browser with the origin private file system",
    );
  }
  if (!pools.has(directory)) {
    pools.set(
      directory,
      s.installOpfsSAHPoolVfs({ name: "gloss-" + directory, directory }),
    );
  }
  return pools.get(directory);
}

export async function open(kind, name, directory) {
  try {
    const s = await sqlite3();
    let db;
    if (kind === "memory") {
      db = new s.oo1.DB(":memory:", "c");
    } else {
      const pool = await opfs(s, directory);
      db = new pool.OpfsSAHPoolDb(name);
    }
    s.capi.sqlite3_extended_result_codes(db.pointer, 1);
    db.exec("pragma foreign_keys = on");
    return new Ok({ s, db });
  } catch (error) {
    return new GError(String(error?.message ?? error));
  }
}

function bindable(cell) {
  if (cell instanceof Null) return null;
  if (cell instanceof Integer) return cell[0];
  if (cell instanceof Real) return cell[0];
  if (cell instanceof Text) return cell[0];
  if (cell instanceof Blob) return cell[0].buffer;
  return null;
}

function failure(handle) {
  const { s, db } = handle;
  return new GError([
    s.capi.sqlite3_extended_errcode(db.pointer),
    s.capi.sqlite3_errmsg(db.pointer),
  ]);
}

// Run one statement: Ok([declared types, rows of cells, affected]) or
// Error([extended code, message]).
export function run(handle, sql, cells) {
  const { s, db } = handle;
  let stmt;
  try {
    stmt = db.prepare(sql);
    const args = cells.toArray().map(bindable);
    if (args.length > 0) stmt.bind(args);
    const columns = stmt.columnCount;
    const declared = [];
    for (let i = 0; i < columns; i++) {
      declared.push(s.capi.sqlite3_column_decltype(stmt.pointer, i) ?? "");
    }
    const rows = [];
    while (stmt.step()) {
      const row = [];
      for (let i = 0; i < columns; i++) {
        row.push(cell(s, stmt, i));
      }
      rows.push(toList(row));
    }
    const affected = columns > 0 ? rows.length : db.changes();
    return new Ok([toList(declared), toList(rows), affected]);
  } catch (_) {
    return failure(handle);
  } finally {
    stmt?.finalize();
  }
}

function cell(s, stmt, i) {
  switch (s.capi.sqlite3_column_type(stmt.pointer, i)) {
    case s.capi.SQLITE_INTEGER:
      return new Integer(Number(stmt.get(i)));
    case s.capi.SQLITE_FLOAT:
      return new Real(stmt.get(i));
    case s.capi.SQLITE_TEXT:
      return new Text(stmt.get(i));
    case s.capi.SQLITE_BLOB:
      return new Blob(new BitArray(stmt.get(i)));
    default:
      return new Null();
  }
}

export function script(handle, sql) {
  try {
    handle.db.exec(sql);
    return new Ok(undefined);
  } catch (_) {
    return failure(handle);
  }
}

export function close(handle) {
  try {
    handle.db.close();
  } catch (_) {}
}
