// bench/xlang/js/main.mjs — Zod's column.
//
// One line out: `<name> <ns/op> <iterations>`. See bench/xlang/README.md.
//
// `JSON.parse` then `schema.parse` is two passes over the value, which is the same arrangement
// Rupa's `decode_json/3` has and for the same reason: the parser will not say which field a
// value belongs to until after it has built it. Building the schema is setup and is not timed.

import { readFileSync } from "node:fs";
import { z } from "zod";

const nonEmpty = z.string().min(1);

const schema = z.object({
  id: nonEmpty,
  name: nonEmpty,
  active: z.boolean(),
  score: z.number().gte(0),
  profile: z.object({
    age: z.int().gte(0).lte(150),
    city: z.string(),
    settings: z.object({ theme: z.string(), size: z.int() }),
  }),
  tags: z.array(nonEmpty),
});

const path = process.argv[2];
const text = readFileSync(path, "utf8");

const decode = (input) => schema.parse(JSON.parse(input));

// The fixture has to parse before anything is timed, so a fast column can never be one that
// quietly failed.
decode(text);

// Both are read from the environment so every column can be re-run at a different warmup with
// one variable, which is the only way to tell a slow library from an under-warmed one.
const warmup = Number(process.env.XLANG_WARMUP ?? 50_000);
const iterations = Number(process.env.XLANG_ITERATIONS ?? 100_000);

let sink = null;
for (let i = 0; i < warmup; i++) sink = decode(text);

const started = process.hrtime.bigint();
for (let i = 0; i < iterations; i++) sink = decode(text);
const elapsed = process.hrtime.bigint() - started;

if (sink === null) throw new Error("unreachable, and here so the loop cannot be optimised away");

console.log(`zod ${(Number(elapsed) / iterations).toFixed(1)} ${iterations}`);
