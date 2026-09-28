defmodule Rupa.Number do
  @moduledoc false

  # Numeric predicates both backends share, kept in one place so `multiple_of:` means the same
  # thing whichever backend ran the decode.

  @doc """
  Whether `value` is an integer multiple of `step`.

  Integers are a plain `rem`. For a float the check is exact rather than a floating quotient:
  each side is read off `Float.to_string/1` as an integer mantissa and a power of ten, both are
  scaled to a common power, and the multiple test is an integer `rem`. So `0.3` is a multiple of
  `0.1` -- which a `value / step` test misses, because `0.3 / 0.1` is `2.999...` -- while
  `0.30000000000000004` is not. There is no division, so nothing overflows or raises.
  """
  @spec multiple?(number(), number()) :: boolean()
  def multiple?(value, step) when is_integer(value) and is_integer(step) do
    step != 0 and rem(value, step) == 0
  end

  def multiple?(value, step) do
    {value_digits, value_exp} = scaled(value)
    {step_digits, step_exp} = scaled(step)
    exp = min(value_exp, step_exp)
    denominator = step_digits * pow10(step_exp - exp)

    denominator != 0 and rem(value_digits * pow10(value_exp - exp), denominator) == 0
  end

  # A number as an integer mantissa and a base-ten exponent, so `value == digits * 10 ** exp`.
  defp scaled(number) when is_integer(number), do: {number, 0}
  defp scaled(number) when is_float(number), do: number |> Float.to_string() |> from_string()

  defp from_string(string) do
    {mantissa, exponent} =
      case String.split(string, "e") do
        [mantissa] -> {mantissa, 0}
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
      end

    {sign, digits} =
      case mantissa do
        "-" <> rest -> {-1, rest}
        _positive -> {1, mantissa}
      end

    # `Float.to_string/1` always writes a decimal point (`"1.0"`, `"1.0e-5"`), so the mantissa
    # always splits into a whole and a fractional part.
    [whole, fraction] = String.split(digits, ".")

    {sign * String.to_integer(whole <> fraction), exponent - String.length(fraction)}
  end

  defp pow10(power), do: Integer.pow(10, power)
end
