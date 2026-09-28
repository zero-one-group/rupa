# Credo runs `--strict` in both aliases, so anything it reports fails the build. Only the
# deviations from Credo's own default set are listed here; everything else is Credo's default.
#
# dev/ is out of scope on purpose: the scripts there are executable prose, not library code,
# and linting them means writing for the linter instead of the reader. mix.exs is out because
# Credo's own default scope leaves it out, and ModuleDoc would fire on the project module.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # The formatter wraps code at 100. This holds comments and docstrings to the same
          # column -- the half the formatter cannot see.
          {Credo.Check.Readability.MaxLineLength, [max_length: 100]},
          # A test module's name is its documentation.
          {Credo.Check.Readability.ModuleDoc, [files: %{excluded: ["test/"]}]},
          # Off in Credo's defaults. On here because a spec is the public contract in the
          # docs, and it is what the compiler's type checker will read as it grows teeth.
          # lib/ only -- test helpers are not API.
          {Credo.Check.Readability.Specs, [files: %{included: ["lib/"]}]}
        ],
        disabled: [
          # The roadmap and the milestone PRs carry the open work. A TODO in the source would
          # fail the gate on every branch that has one, which teaches you to delete the note
          # rather than the debt. TagFIXME stays on: that one means broken, not later.
          {Credo.Check.Design.TagTODO, []}
        ]
      }
    }
  ]
}
