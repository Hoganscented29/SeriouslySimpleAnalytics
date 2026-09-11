defmodule WebAnalytics.Geo.MMDB do
  @moduledoc """
  A reader for the MaxMind DB (`.mmdb`) binary format.

  Written by hand rather than pulled in as a dependency, because the project
  rule is not to add dependencies and the format is small enough to implement
  directly. It reads any MaxMind-format database — MaxMind's own GeoLite2 and
  DB-IP's Lite city database both work unchanged.

  ## The format

  A database is three parts: a binary search tree, a data section, and a
  metadata block at the end.

  The tree has one node per bit-decision, each holding two fixed-width records
  (24, 28 or 32 bits). Looking up an address means walking its bits from the
  most significant, taking the left record on a 0 and the right on a 1. A record
  below `node_count` is the next node; one equal to it means the address is not
  in the database; one above it is an offset into the data section.

  The data section is a tagged-value encoding — maps, arrays, strings, numbers —
  where repeated values are deduplicated by pointers back to earlier offsets.
  That is why decoding follows pointers rather than reading straight through.

  The whole file is held as one binary and read with `binary_part/3`, which
  returns sub-binaries that share the original's memory rather than copying it.
  A lookup is therefore pure arithmetic over shared memory: no file I/O, no
  allocation to speak of, and no process to serialise through.
  """

  import Bitwise

  # The metadata block is preceded by this marker and is guaranteed by the spec
  # to sit within the last 128KB, so there is no need to scan the whole file.
  @marker <<0xAB, 0xCD, 0xEF>> <> "MaxMind.com"
  @metadata_window 128 * 1024

  # A 16-byte run of zeroes separates the search tree from the data section, and
  # data-section offsets are stored with that separator already added in.
  @data_separator 16

  @valid_record_sizes [24, 28, 32]

  # The struct carries the entire database binary; never inspect it wholesale.
  @derive {Inspect, only: [:database_type, :build_epoch, :ip_version, :node_count, :record_size]}
  defstruct [
    :data,
    :node_count,
    :record_size,
    :node_byte_size,
    :data_start,
    :ip_version,
    :ipv4_start_node,
    :database_type,
    :build_epoch,
    :metadata
  ]

  @type t :: %__MODULE__{}

  @doc """
  Loads a database from disk.

  The file is read once, in full, and kept in memory for the life of the struct.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, data} <- File.read(path),
         {:ok, metadata_start} <- find_metadata(data),
         {metadata, _offset} when is_map(metadata) <-
           decode(data, metadata_start, metadata_start) do
      build(data, metadata)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_metadata}
    end
  end

  @doc """
  Looks up an address.

  Accepts an `:inet` address tuple or a string. Returns the decoded record, or
  `:not_found` when the database has no entry covering the address.
  """
  @spec lookup(t(), :inet.ip_address() | String.t()) :: {:ok, map()} | :not_found
  def lookup(db, address)

  def lookup(%__MODULE__{} = db, address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} -> lookup(db, parsed)
      {:error, _} -> :not_found
    end
  end

  def lookup(%__MODULE__{} = db, {a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    value = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

    # An IPv6 database stores IPv4 under ::ffff:0:0/96, so the walk starts from
    # the node reached by 96 zero bits rather than from the root.
    start = if db.ip_version == 6, do: db.ipv4_start_node, else: 0
    traverse(db, value, 32, start, 0)
  end

  def lookup(%__MODULE__{ip_version: 6} = db, {a, b, c, d, e, f, g, h}) do
    value =
      a <<< 112 ||| b <<< 96 ||| c <<< 80 ||| d <<< 64 ||| e <<< 48 ||| f <<< 32 ||| g <<< 16 |||
        h

    traverse(db, value, 128, 0, 0)
  end

  # An IPv6 address against an IPv4-only database.
  def lookup(%__MODULE__{}, _address), do: :not_found

  @doc "A one-line description of the loaded database, for logs and the UI."
  def describe(%__MODULE__{} = db) do
    built =
      case DateTime.from_unix(db.build_epoch || 0) do
        {:ok, at} -> Calendar.strftime(at, "%Y-%m-%d")
        _ -> "unknown"
      end

    "#{db.database_type || "unknown"} (built #{built}, #{db.node_count} nodes)"
  end

  # -- construction --------------------------------------------------------

  defp build(data, metadata) do
    node_count = metadata["node_count"]
    record_size = metadata["record_size"]

    cond do
      not is_integer(node_count) or node_count <= 0 ->
        {:error, :invalid_node_count}

      record_size not in @valid_record_sizes ->
        {:error, {:unsupported_record_size, record_size}}

      true ->
        node_byte_size = div(record_size * 2, 8)

        db = %__MODULE__{
          data: data,
          node_count: node_count,
          record_size: record_size,
          node_byte_size: node_byte_size,
          data_start: node_count * node_byte_size + @data_separator,
          ip_version: metadata["ip_version"] || 4,
          database_type: metadata["database_type"],
          build_epoch: metadata["build_epoch"],
          metadata: metadata
        }

        {:ok, %{db | ipv4_start_node: ipv4_start_node(db)}}
    end
  end

  # Walks the 96 leading zero bits of ::ffff:0:0/96 once at load time, so every
  # IPv4 lookup can skip them.
  defp ipv4_start_node(%{ip_version: 6} = db) do
    Enum.reduce_while(1..96, 0, fn _bit, node ->
      if node >= db.node_count, do: {:halt, node}, else: {:cont, read_record(db, node, 0)}
    end)
  end

  defp ipv4_start_node(_db), do: 0

  defp find_metadata(data) do
    size = byte_size(data)
    window = min(size, @metadata_window)
    offset = size - window

    case :binary.matches(binary_part(data, offset, window), @marker) do
      [] ->
        {:error, :metadata_not_found}

      matches ->
        {position, length} = List.last(matches)
        {:ok, offset + position + length}
    end
  end

  # -- tree ----------------------------------------------------------------

  defp traverse(db, value, bits, node, depth) do
    cond do
      node > db.node_count ->
        # Record values above node_count point into the data section, with the
        # node count and the separator folded in.
        offset = db.data_start + (node - db.node_count - @data_separator)
        {record, _} = decode(db.data, offset, db.data_start)
        {:ok, record}

      node == db.node_count ->
        :not_found

      depth >= bits ->
        :not_found

      true ->
        bit = value >>> (bits - 1 - depth) &&& 1
        traverse(db, value, bits, read_record(db, node, bit), depth + 1)
    end
  end

  defp read_record(%{record_size: 24} = db, node, index) do
    uint(db.data, node * db.node_byte_size + index * 3, 3)
  end

  # A 28-bit node packs the two records' high nibbles into the middle byte:
  # bytes 0-2 are the left record's low bits, byte 3 holds the left record's
  # high nibble and the right record's high nibble, bytes 4-6 the right's low.
  defp read_record(%{record_size: 28} = db, node, 0) do
    base = node * db.node_byte_size
    <<low::24, middle::8>> = binary_part(db.data, base, 4)
    (middle &&& 0xF0) <<< 20 ||| low
  end

  defp read_record(%{record_size: 28} = db, node, 1) do
    base = node * db.node_byte_size
    <<middle::8, low::24>> = binary_part(db.data, base + 3, 4)
    (middle &&& 0x0F) <<< 24 ||| low
  end

  defp read_record(%{record_size: 32} = db, node, index) do
    uint(db.data, node * db.node_byte_size + index * 4, 4)
  end

  # -- data section --------------------------------------------------------

  defp decode(data, offset, data_start) do
    <<control::8>> = binary_part(data, offset, 1)
    offset = offset + 1

    # Type 0 means the real type is in the next byte, biased by 7.
    {type, offset} =
      case control >>> 5 do
        0 -> {uint(data, offset, 1) + 7, offset + 1}
        type -> {type, offset}
      end

    if type == 1 do
      {target, next} = pointer(data, control, offset)
      {value, _} = decode(data, data_start + target, data_start)
      {value, next}
    else
      {size, offset} = payload_size(data, control, offset)
      payload(data, type, size, offset, data_start)
    end
  end

  defp payload(data, 2, size, offset, _start),
    do: {binary_part(data, offset, size), offset + size}

  defp payload(data, 3, _size, offset, _start) do
    <<value::float-size(64)>> = binary_part(data, offset, 8)
    {value, offset + 8}
  end

  defp payload(data, 4, size, offset, _start),
    do: {binary_part(data, offset, size), offset + size}

  defp payload(data, type, size, offset, _start) when type in [5, 6, 9, 10] do
    {uint(data, offset, size), offset + size}
  end

  defp payload(data, 7, size, offset, start), do: decode_map(data, size, offset, start, %{})

  defp payload(data, 8, size, offset, _start), do: {int(data, offset, size), offset + size}

  defp payload(data, 11, size, offset, start), do: decode_array(data, size, offset, start, [])

  # Cache containers and end markers only appear in the data section's internal
  # structure, never as a value reached by a lookup.
  defp payload(_data, 12, _size, offset, _start), do: {nil, offset}
  defp payload(_data, 13, _size, offset, _start), do: {nil, offset}
  defp payload(_data, 14, size, offset, _start), do: {size == 1, offset}

  defp payload(data, 15, _size, offset, _start) do
    <<value::float-size(32)>> = binary_part(data, offset, 4)
    {value, offset + 4}
  end

  defp payload(_data, type, _size, _offset, _start) do
    raise ArgumentError, "unknown MaxMind DB data type #{type}"
  end

  defp decode_map(_data, 0, offset, _start, acc), do: {acc, offset}

  defp decode_map(data, remaining, offset, start, acc) do
    {key, offset} = decode(data, offset, start)
    {value, offset} = decode(data, offset, start)
    decode_map(data, remaining - 1, offset, start, Map.put(acc, key, value))
  end

  defp decode_array(_data, 0, offset, _start, acc), do: {Enum.reverse(acc), offset}

  defp decode_array(data, remaining, offset, start, acc) do
    {value, offset} = decode(data, offset, start)
    decode_array(data, remaining - 1, offset, start, [value | acc])
  end

  # The low 5 bits of the control byte are the size, with three escape values
  # that borrow following bytes for larger payloads.
  defp payload_size(data, control, offset) do
    case control &&& 0x1F do
      size when size < 29 -> {size, offset}
      29 -> {29 + uint(data, offset, 1), offset + 1}
      30 -> {285 + uint(data, offset, 2), offset + 2}
      _ -> {65_821 + uint(data, offset, 3), offset + 3}
    end
  end

  # A pointer's control byte carries both its width and the top 3 bits of its
  # value. The constants make the encodable ranges disjoint, so every offset has
  # exactly one representation.
  defp pointer(data, control, offset) do
    high = control &&& 0x07

    case control >>> 3 &&& 0x03 do
      0 -> {high <<< 8 ||| uint(data, offset, 1), offset + 1}
      1 -> {(high <<< 16 ||| uint(data, offset, 2)) + 2_048, offset + 2}
      2 -> {(high <<< 24 ||| uint(data, offset, 3)) + 526_336, offset + 3}
      _ -> {uint(data, offset, 4), offset + 4}
    end
  end

  defp uint(_data, _offset, 0), do: 0

  defp uint(data, offset, size) do
    :binary.decode_unsigned(binary_part(data, offset, size), :big)
  end

  # Signed integers drop leading zero bytes, so a short value is always positive
  # and only a full-width one can carry a sign bit.
  defp int(_data, _offset, 0), do: 0

  defp int(data, offset, size) do
    bits = size * 8
    <<value::signed-size(^bits)>> = binary_part(data, offset, size)
    value
  end
end
