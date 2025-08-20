defmodule SampleApp.Image do
  @moduledoc """
  AtomVM-safe image utilities.

  - Fast chunk conversion: RGB565 **little-endian** → RGB888 (3 bytes/pixel),
    with selectable source order (:rgb or :bgr) to fix red/blue swaps.
  - bpp detection from file size.
  """

  import Bitwise

  @doc """
  Back-compat wrapper (assumes :rgb). Prefer `rgb565le_to_rgb888_chunk/2`.
  """
  @spec rgb565le_to_rgb888_chunk(binary()) :: binary()
  def rgb565le_to_rgb888_chunk(bin), do: rgb565le_to_rgb888_chunk(bin, :rgb)

  @doc """
  Convert a binary of RGB565 **little-endian** pixels (`<<lo,hi, lo,hi, ...>>`)
  into RGB888 (`<<r,g,b, r,g,b, ...>>`).

  `order` is `:rgb` for true RGB565, or `:bgr` when your source uses BGR565
  (common for BMP-style dumps). Any trailing odd byte is ignored safely.
  """
  @spec rgb565le_to_rgb888_chunk(binary(), :rgb | :bgr) :: binary()
  def rgb565le_to_rgb888_chunk(bin, order), do: conv(bin, <<>>, order)

  # Done
  defp conv(<<>>, acc, _order), do: acc
  # Odd trailing byte — ignore safely
  defp conv(<<_lo>>, acc, _order), do: acc

  # Hot path: two bytes -> three bytes
  defp conv(<<lo, hi, rest::binary>>, acc, order) do
    # 16-bit little-endian value
    val = bor(lo, bsl(hi, 8))

    # Extract channels in RGB565 layout
    r5 = band(bsr(val, 11), 0x1F)
    g6 = band(bsr(val, 5), 0x3F)
    b5 = band(val, 0x1F)

    # Expand to 8-bit (bit replication)
    r8 = bor(bsl(r5, 3), bsr(r5, 2))
    g8 = bor(bsl(g6, 2), bsr(g6, 4))
    b8 = bor(bsl(b5, 3), bsr(b5, 2))

    # Swap R/B if the *source* is BGR565
    {rr, gg, bb} =
      case order do
        :bgr -> {b8, g8, r8}
        _ -> {r8, g8, b8}
      end

    conv(rest, <<acc::binary, rr, gg, bb>>, order)
  end

  @doc """
  Given a file size (bytes) and pixel count, return `2`, `3`, or `:unknown`.
  Useful for validating `.RGB` files (16-bit vs 24-bit payloads).
  """
  @spec bpp_from_size(non_neg_integer(), pos_integer()) :: 2 | 3 | :unknown
  def bpp_from_size(size_bytes, pixels) when pixels > 0 do
    cond do
      size_bytes == pixels * 2 -> 2
      size_bytes == pixels * 3 -> 3
      true -> :unknown
    end
  end
end
