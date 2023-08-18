# Copyright 2023 Toskr, Inc.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
defprotocol OpentelemetryDSL.Encoder do
  @moduledoc """
  `Protocol` to determine how Elixir values are encoded as OpenTelemetry attribute values.

  Default implementations are provided for all built-in Elixir types.

  ## Adding Custom Implementations

  If you would like to implement this protocol for a custom type (i.e. a struct), you
  must ensure the `OpentelemetryDSL.Encoder.encode/1` function returns a value with a type the
  OpenTelemetry SDK accepts. If `encode/1` does not, the associated span attribute will be
  silently dropped by the OpenTelemetry SDK and will not appear in the span's attribute map.

  The OpenTelemetry SDK supports the following Elixir types:

  * any `Atom`
  * any `Boolean`
  * any `Integer`
  * any `Float`
  * any `BitString`
  * any homogeneous, de-nested `Tuple`
  * any homogeneous, de-nested, proper `List`

  ### Returning Multiple Attributes

  In some cases you may wish to split a single value into multiple OpenTelemetry span attributes.
  To do so, you can have `encode/1` return a de-nested `Map` of span attributes, where the keys
  are the name of each span attribute, and the values are the encoded values.

  One such example of this approach is the default implementation for `Map`, where each key in the
  map is converted to a new attribute and merged into the span's attribute map.

  For example, consider the following call to `trace_attrs/1`:

  ```elixir
  trace_attrs my_map: %{a: "apple", b: "banana", c: "coconut"},
              my_string: "string",
              my_list: [1, 2, 3]
  ```

  This will produce the following span attribute map:

  ```elixir
  %{
    "my_map.a" => "apple",
    "my_map.b" => "banana",
    "my_map.c" => "coconut",
    "my_string" => "string",
    "my_list" => [1, 2, 3]
  }
  ```
  """

  @doc """
  Encodes the given Elixir term as an OpenTelemetry attribute value.
  """

  @fallback_to_any true

  @type otel_encoded :: OpenTelemetry.attribute_value()
  @type otel_map :: %{OpenTelemetry.attribute_key() => OpenTelemetry.attribute_value()}
  @type otel_error ::
          :otel_no_encoder
          | :otel_invalid_type_in_list
          | :otel_heterogeneous_list
          | :otel_improper_list
          | :otel_nested_list
          | :otel_nested_tuple
          | :otel_nested_map

  @spec encode(t()) :: otel_encoded() | otel_map() | otel_error()
  def encode(term)
end

defimpl OpentelemetryDSL.Encoder, for: Any do
  def encode(_term) do
    :otel_no_encoder
  end
end

defimpl OpentelemetryDSL.Encoder, for: [PID, Port, Reference, Function] do
  def encode(term) do
    inspect(term)
  end
end

defimpl OpentelemetryDSL.Encoder, for: [Integer, Float, BitString, Atom] do
  def encode(term) do
    term
  end
end

defimpl OpentelemetryDSL.Encoder, for: Map do
  def encode(term) do
    Enum.into(term, Map.new(), fn {key, value} ->
      {key, OpentelemetryDSL.Encoder.encode(value)}
    end)
  end
end

defimpl OpentelemetryDSL.Encoder, for: Tuple do
  def encode(term) do
    term
    |> Tuple.to_list()
    |> OpentelemetryDSL.Encoder.encode()
  end
end

defimpl OpentelemetryDSL.Encoder, for: List do
  def encode(term) do
    if List.improper?(term) do
      :otel_improper_list
    else
      encode_proper_list(term)
    end
  end

  defp encode_proper_list(term) do
    encoded = for item <- term, do: OpentelemetryDSL.Encoder.encode(item)
    types = for item <- encoded, uniq: true, do: typeof(item)

    cond do
      length(types) > 1 -> :otel_heterogeneous_list
      :invalid in types -> :otel_invalid_type_in_list
      :list in types -> :otel_nested_list
      :tuple in types -> :otel_nested_tuple
      :map in types -> :otel_nested_map
      encoded -> encoded
    end
  end

  defp typeof(term) when is_atom(term), do: :atom
  defp typeof(term) when is_boolean(term), do: :boolean
  defp typeof(term) when is_integer(term), do: :integer
  defp typeof(term) when is_float(term), do: :float
  defp typeof(term) when is_bitstring(term), do: :bitstring
  defp typeof(term) when is_list(term), do: :list
  defp typeof(term) when is_map(term), do: :map
  defp typeof(term) when is_tuple(term), do: :tuple
  # if encode/1 returns a value we cannot encode into a list
  defp typeof(_), do: :invalid
end
