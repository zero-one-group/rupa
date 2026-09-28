# JSON-Schema-Test-Suite, vendored

From [json-schema-org/JSON-Schema-Test-Suite][upstream], commit
`80c87e8fca8b207a7a7ae944b875f0fcf889f46a` (2026-09-16), `tests/draft2020-12/`. MIT-licensed;
the upstream notice is in `LICENSE` beside this file, and travels with the copy.

[upstream]: https://github.com/json-schema-org/JSON-Schema-Test-Suite

Vendored rather than cloned so that `mix check.all` runs offline and on one fixed corpus: a gate
that needs the network is a gate that can quietly not run. It is trimmed to what Rupa claims. The
top-level files are the keywords Rupa reads, which `test/rupa/json_schema_suite_test.exs` runs.
`optional/format/` holds the ten formats Rupa has, which `test/rupa/format_suite_test.exs` runs.
The rest of draft2020-12 is not a Rupa deviation; it is a keyword or format Rupa does not have.
`mix.exs`'s `files:` excludes `test/`, so none of this ships.

To take a newer upstream: copy the same file names out of `tests/draft2020-12/`, update the
commit above, and run the suite. A case the new corpus adds either passes, or joins the skip
reasons in `Rupa.JsonSchema`, or is a bug.
