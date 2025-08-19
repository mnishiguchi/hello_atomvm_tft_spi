defmodule SampleApp.Image do
  @moduledoc """
  Image utilities that are safe on AtomVM.

  Currently provides a fast, allocation-friendly conversion from **RGB565
  (little-endian)** to **RGB888** (3 bytes per pixel), suitable for sending to
  the ILI9488 configured in 18-bit (RGB666) mode.

  ## Examples

      iex> SampleApp.Image.rgb565le_to_rgb888_chunk(<<0x1F, 0x00>>)   # 0x001F (blue max)
      <<0, 0, 255>>

      iex> SampleApp.Image.rgb565le_to_rgb888_chunk(<<0x00, 0xF8>>)   # 0xF800 (red max)
      <<255, 0, 0>>

      iex> SampleApp.Image.rgb565le_to_rgb888_chunk(<<0xE0, 0x07>>)   # 0x07E0 (green max)
      <<0, 255, 0>>
  """

  import Bitwise

  @doc """
  Convert a binary `bin` containing RGB565 **little-endian** pixels
  (`<<lo,hi, lo,hi, ...>>`) into an RGB888 binary (`<<r,g,b, r,g,b, ...>>`).

  * Ignores a trailing odd byte (should not happen with our chunking).
  * Pure and reentrant; chunk-friendly for streaming.
  """
  @spec rgb565le_to_rgb888_chunk(binary()) :: binary()
  def rgb565le_to_rgb888_chunk(bin), do: conv(bin, <<>>)

  # Done
  defp conv(<<>>, acc), do: acc
  # Odd trailing byte — ignore safely
  defp conv(<<_lo>>, acc), do: acc

  # Hot path: two bytes -> three bytes
  defp conv(<<lo, hi, rest::binary>>, acc) do
    # 16-bit little-endian value
    val = bor(lo, bsl(hi, 8))
    # Extract channels
    r5 = band(bsr(val, 11), 0x1F)
    g6 = band(bsr(val, 5), 0x3F)
    b5 = band(val, 0x1F)
    # Expand to 8-bit (bit replication)
    r8 = bor(bsl(r5, 3), bsr(r5, 2))
    g8 = bor(bsl(g6, 2), bsr(g6, 4))
    b8 = bor(bsl(b5, 3), bsr(b5, 2))
    conv(rest, <<acc::binary, r8, g8, b8>>)
  end

  @doc """
  Given a file size (bytes) and pixel count, return `2`, `3`, or `:unknown`.
  Useful for validating `.RGB` files for 16-bit vs 24-bit payloads.
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
