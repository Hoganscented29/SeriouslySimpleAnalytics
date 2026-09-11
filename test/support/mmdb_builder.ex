defmodule WebAnalytics.MMDBBuilder do
  @moduledoc """
  Builds a tiny MaxMind-format database in memory, for testing the reader.

  The real databases are ~120MB and fetched separately, so they cannot be a test
  fixture. This writes just enough of the format — a one-node tree, a data
  section and a metadata block — to exercise the tree walk, the record layouts
  and the value decoding against bytes whose meaning is known exactly.

  Only the subset the reader needs is implemented, and only for small payloads:
  every size here is under 29, so the multi-byte size escapes never come up.
  """

  import Bitwise

  @marker <<0xAB, 0xCD, 0xEF>> <> "MaxMind.com"

  @doc """
  Builds a database whose first address bit selects between two records.

  Addresses with a leading 0 bit resolve to `left`, those with a leading 1 to
  `right`. That is the smallest tree that proves the walk actually reads the
  address rather than always returning the same value.
  """
  def build(left, right, opts \\ []) do
    record_size = Keyword.get(opts, :record_size, 32)
    ip_version = Keyword.get(opts, :ip_version, 4)

    left_data = encode(left)
    right_data = encode(right)
    data_section = left_data <> right_data

    node_count = 1

    # Record values are the data-section offset plus node_count plus the
    # 16-byte separator, which is how the reader tells a data pointer from a
    # node index.
    left_record = node_count + 16 + 0
    right_record = node_count + 16 + byte_size(left_data)

    tree = encode_node(left_record, right_record, record_size)
    separator = :binary.copy(<<0>>, 16)

    metadata =
      encode(%{
        "node_count" => {:uint32, node_count},
        "record_size" => {:uint16, record_size},
        "ip_version" => {:uint16, ip_version},
        "database_type" => "Test-City",
        "binary_format_major_version" => {:uint16, 2},
        "binary_format_minor_version" => {:uint16, 0},
        "build_epoch" => {:uint32, 1_700_000_000},
        "languages" => ["en"],
        "description" => %{"en" => "test"}
      })

    tree <> separator <> data_section <> @marker <> metadata
  end

  @doc "Writes a built database to a temporary file and returns its path."
  def write!(binary) do
    path =
      Path.join(
        System.tmp_dir!(),
        "wa-test-#{System.unique_integer([:positive])}.mmdb"
      )

    File.write!(path, binary)
    path
  end

  defp encode_node(left, right, 32) do
    <<left::32, right::32>>
  end

  defp encode_node(left, right, 24) do
    <<left::24, right::24>>
  end

  # A 28-bit node folds each record's high nibble into the shared middle byte.
  defp encode_node(left, right, 28) do
    middle = (left >>> 24 &&& 0x0F) <<< 4 ||| (right >>> 24 &&& 0x0F)
    <<left::24, middle::8, right::24>>
  end

  defp encode(value) when is_binary(value), do: control(2, byte_size(value)) <> value

  defp encode({:uint16, value}), do: encode_uint(5, value)
  defp encode({:uint32, value}), do: encode_uint(6, value)

  defp encode(value) when is_integer(value), do: encode_uint(6, value)

  defp encode(true), do: control(14, 1)
  defp encode(false), do: control(14, 0)

  defp encode(value) when is_float(value), do: control(3, 8) <> <<value::float-64>>

  defp encode(value) when is_map(value) do
    body = Enum.map_join(value, fn {key, entry} -> encode(to_string(key)) <> encode(entry) end)
    control(7, map_size(value)) <> body
  end

  defp encode(value) when is_list(value) do
    control(11, length(value)) <> Enum.map_join(value, &encode/1)
  end

  defp encode_uint(type, 0), do: control(type, 0)

  defp encode_uint(type, value) do
    bytes = :binary.encode_unsigned(value, :big)
    control(type, byte_size(bytes)) <> bytes
  end

  # Only types 1-7 fit in the control byte's three type bits. Everything above
  # is an "extended" type: the control byte's type is 0 and a second byte
  # carries the real type, biased by 7.
  defp control(type, size) when type <= 7 and size < 29 do
    <<type::3, size::5>>
  end

  defp control(type, size) when size < 29 do
    <<0::3, size::5, type - 7::8>>
  end
end
