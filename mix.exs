defmodule Rupa.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/zero-one-group/rupa"

  # `:json` is stdlib from OTP 27 and Rupa is written against it with no fallback. An older
  # runtime would compile Rupa and then fail the first `Rupa.compile/1` with an
  # `UndefinedFunctionError` from inside staging; this says the same thing at `mix deps.get`.
  if String.to_integer(System.otp_release()) < 27 do
    Mix.raise(
      "Rupa needs Erlang/OTP 27 or newer, because `:json` is stdlib from there; " <>
        "this is OTP #{System.otp_release()}"
    )
  end

  def project do
    [
      app: :rupa,
      version: @version,
      # OTP 27 is the real floor: `:json` is stdlib from there, and fused decoding is written
      # against it with no fallback to write, test or benchmark. 1.18 is the oldest Elixir that
      # is comfortable on OTP 27; CI compiles and tests that pair beside the pinned one
      # (.github/workflows/ci.yml).
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Enforced here rather than per-run with `--warnings-as-errors`: any file the incremental
      # compiler touches is held to it. `mix test` compiles test/ itself, outside this, so the
      # aliases pass the flag there as well.
      elixirc_options: elixirc_options(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: "A macro-less, serde-like schema library for Elixir. Schemas are plain data.",
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      source_url: @source_url
    ]
  end

  # Rupa starts nothing and never logs. `:json` lives in `:stdlib`, which is always there, so
  # there is no application to name.
  def application do
    []
  end

  # `check.all` runs the suite, which refuses to run outside the test env.
  def cli do
    [
      preferred_envs: [
        "check.all": :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp deps do
    [
      # The only dependency that reaches `lib/`, and an optional one: `Rupa.Gen` compiles when
      # `stream_data` is there and does not exist when it is not, so a project that wants
      # generators adds it and everyone else ships Rupa with nothing behind it.
      {:stream_data, "~> 1.4", optional: true},

      # Tooling. Rupa has no required dependencies and 0.1.0 ships none.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},

      # What `bench/compare.exs` measures Rupa against, and nothing else uses. `only: :dev`
      # keeps them out of the test env and out of the package: a comparison is a claim this
      # repo has to be able to reproduce, not something anyone installing Rupa should carry.
      {:peri, "~> 0.11", only: :dev},
      {:ecto, "~> 3.14", only: :dev}
    ]
  end

  defp aliases do
    [
      # The gate. `--warnings-as-errors` because `mix test` compiles test/ outside
      # `elixirc_options`; without it a warning in test/ is the one kind the gate would let
      # through. `coveralls` rather than `test`, for the threshold in coveralls.json.
      #
      # No Dialyzer. The compiler's own type checker is the one that will still be here, and
      # `elixirc_options` already makes everything it says an error.
      "check.all": [
        "format --check-formatted",
        "compile",
        "credo --strict",
        "coveralls --warnings-as-errors"
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://rupa.hexdocs.pm/changelog.html"
      },
      # Hex's defaults minus the scaffolding. There is no `priv/` and no assets to ship: the
      # README's images are absolute URLs.
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      name: "Rupa",
      main: "readme",
      # The README opens with the lockup image rather than an `# Rupa` heading, so ExDoc is told
      # the page title; the tile is the sidebar logo and the favicon. See assets/README.md.
      logo: "assets/rupa-avatar.svg",
      favicon: "assets/rupa-avatar.svg",
      assets: %{"assets" => "assets"},
      extras: [{"README.md", title: "Rupa"}, "CHANGELOG.md"],
      # Three groups, because the sidebar otherwise lists the staging pass beside the
      # constructors and gives a reader no way to tell which one they are meant to reach for.
      # "Inside" is documented on purpose -- the architecture is the pitch, so following it
      # should be possible -- but nobody needs to call any of it.
      groups_for_modules: [
        "The API": [
          Rupa,
          Rupa.T,
          Rupa.Schema,
          Rupa.Error,
          Rupa.Format,
          Rupa.Gen,
          Rupa.Json,
          Rupa.JsonSchema
        ],
        Exceptions: [Rupa.DecodeError, Rupa.EncodeError, Rupa.SchemaError],
        Inside: [Rupa.Stage, Rupa.IR, Rupa.Codec, Rupa.Closure, Rupa.Codegen, Rupa.Explain]
      ],
      # `mix docs` is a gate, so a broken or missing reference fails the build rather than
      # scrolling past in the output.
      warnings_as_errors: true,
      # `Rupa.IR.t()` is the union of the node structs, and those are `@moduledoc false` on
      # purpose: `Rupa.IR` documents the set and `Rupa.explain/1` is how you read one, so nine
      # one-line pages would be nine pages of noise. ExDoc has nothing to link them to and says
      # so once per spec. What this costs, plainly: an undefined type in a spec on this page
      # would not be reported here. The compiler catches that anyway, since `elixirc_options`
      # makes an unknown type in a `@spec` an error.
      skip_undefined_reference_warnings_on: fn id -> id == "Rupa.IR" end,
      # The release tag. Every "view source" link on hexdocs points at it, so it moves only
      # when the version does -- and 404s until the tag exists.
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp elixirc_options(:prod), do: []
  defp elixirc_options(_env), do: [warnings_as_errors: true]
end
