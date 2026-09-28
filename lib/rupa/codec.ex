defmodule Rupa.Codec do
  @moduledoc """
  What `Rupa.compile/1` hands back: a staged schema and the decoder built from it.

  You do not call the decoder yourself — `Rupa.decode/3` does, because the same call has to
  work for a codec compiled into a module in M3. What a codec is good for on its own is
  `Rupa.explain/1`, which prints the staged program it carries.
  """

  alias Rupa.Closure
  alias Rupa.IR

  @type t :: %__MODULE__{
          schema: term(),
          program: IR.program(),
          decode: Closure.decoder(),
          defs: %{atom() => Closure.decoder()},
          encode: Closure.decoder(),
          encode_defs: %{atom() => Closure.decoder()},
          json: Closure.decoder(),
          json_defs: %{atom() => Closure.decoder()}
        }

  @enforce_keys [:schema, :program, :decode, :defs, :encode, :encode_defs, :json, :json_defs]
  defstruct [:schema, :program, :decode, :defs, :encode, :encode_defs, :json, :json_defs]

  @doc """
  Builds every direction for a staged program and wraps them together.

  Three trees rather than two since M7: decode, encode to a wire term, and encode straight to
  JSON iodata. `Rupa.decode_json/3` needs no tree of its own — it parses and then decodes.

  `Rupa.compile/1` is the way in; this takes the normalised schema and the staged program:

      schema = Rupa.Schema.normalize(%{name: Rupa.T.string()})
      {:ok, program} = Rupa.Stage.run(schema)
      Rupa.Codec.new(schema, program)
      #=> #Rupa.Codec<object (1 field, unknown: strip)>
  """
  @spec new(term(), IR.program()) :: t()
  def new(schema, program) do
    {decode, defs} = Closure.build(program)
    {encode, encode_defs} = Closure.build_encoder(program)
    {json, json_defs} = Closure.build_json(program)

    struct!(__MODULE__,
      schema: schema,
      program: program,
      decode: decode,
      defs: defs,
      encode: encode,
      encode_defs: encode_defs,
      json: json,
      json_defs: json_defs
    )
  end
end

defimpl Inspect, for: Rupa.Codec do
  import Inspect.Algebra

  @spec inspect(Rupa.Codec.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(%Rupa.Codec{program: %{root: root}}, _opts) do
    concat(["#Rupa.Codec<", Rupa.Explain.summary(root), ">"])
  end
end
