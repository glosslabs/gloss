import { PGlite } from "@electric-sql/pglite";
import { Ok, Error as GError, toList } from "../gleam.mjs";
import { Some, None } from "../../gleam_stdlib/gleam/option.mjs";

// Every type's values are handed over as Postgres's text, unparsed, and
// arguments go in as text, so gloss/sql decodes them exactly as gloss/pg
// does on the BEAM. PGlite only parses the types it has parsers for, so
// replacing those (rather than adding one per type) keeps queries as fast
// as with its defaults.
function textTypes(pg) {
  const identity = (value) => value;
  for (const oid of Object.keys(pg.parsers)) pg.parsers[oid] = identity;
  for (const oid of Object.keys(pg.serializers)) pg.serializers[oid] = identity;
}

export async function open(dataDir) {
  try {
    const pg = await PGlite.create(dataDir === "" ? undefined : dataDir);
    await pg.exec("set timezone = 'UTC'; set datestyle = 'ISO, MDY';");
    textTypes(pg);
    return new Ok({ pg });
  } catch (error) {
    return new GError(String(error?.message ?? error));
  }
}

function failure(error) {
  if (error?.code === undefined) {
    return new GError(
      toList([["C", "08006"], ["M", String(error?.message ?? error)]]),
    );
  }
  const fields = [
    ["C", error.code],
    ["M", error.message ?? ""],
    ["V", error.severity ?? ""],
    ["n", error.constraint ?? ""],
    ["c", error.column ?? ""],
  ];
  return new GError(toList(fields));
}

// Run one statement with text arguments (null for NULL):
// Ok([type oids, rows of Option(text), affected]) or Error(fields).
export async function run(handle, sql, args) {
  try {
    const params = args.toArray().map((arg) =>
      arg instanceof Some ? arg[0] : null,
    );
    const result = await handle.pg.query(sql, params, { rowMode: "array" });
    const oids = result.fields.map((field) => field.dataTypeID);
    const rows = result.rows.map((row) =>
      toList(
        row.map((cell) =>
          cell === null || cell === undefined ? new None() : new Some(String(cell)),
        ),
      ),
    );
    const affected =
      result.fields.length > 0 ? result.rows.length : (result.affectedRows ?? 0);
    return new Ok([toList(oids), toList(rows), affected]);
  } catch (error) {
    return failure(error);
  }
}

export async function script(handle, sql) {
  try {
    await handle.pg.exec(sql);
    return new Ok(undefined);
  } catch (error) {
    return failure(error);
  }
}

export async function close(handle) {
  try {
    await handle.pg.close();
  } catch (_) {}
}
