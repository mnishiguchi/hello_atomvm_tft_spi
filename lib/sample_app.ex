defmodule SampleApp do
  @moduledoc """
  ILI9488 over SPI (RGB666/18-bit) with SD card (FAT) image blitting.
  Target: Seeed XIAO-ESP32S3 running AtomVM.

  Boot:
    1) Initialize display
    2) Draw quick color bars
    3) Mount /sdcard and list files
    4) Blit the first .RGB file as 480×320 (auto-detect RGB565 or 3-byte RGB by file size)
  """

  import Bitwise

  # SPI wiring (XIAO: D8→GPIO7, D9→GPIO8, D10→GPIO9; TFT CS on GPIO43)
  @spi_config [
    bus_config: [sclk: 7, miso: 8, mosi: 9],
    device_config: [
      spi_dev_tft: [
        cs: 43,
        mode: 0,
        clock_speed_hz: 20_000_000,
        command_len_bits: 0,
        address_len_bits: 0
      ]
    ]
  ]

  # Shared bus chip selects (keep HIGH when idle)
  # D7  Touch CS
  @pin_touch_cs 44
  # D3  SD CS
  @pin_sd_cs 4

  # SD mount
  @sd_driver ~c"sdspi"
  @sd_root ~c"/sdcard"

  # SD read chunk aligned to ~4 KiB and multiple of 12 (3 B/px × 4B)
  @bytes_per_pixel_rgb666 3
  @dma_alignment_bytes 4
  @target_chunk_bytes 4 * 1024
  # 4092
  @sd_chunk_bytes @target_chunk_bytes -
                    rem(@target_chunk_bytes, @bytes_per_pixel_rgb666 * @dma_alignment_bytes)

  # Panel geometry
  @panel_w 480
  @panel_h 320

  alias SampleApp.TFT
  alias SampleApp.SD

  def start() do
    :io.format(~c"ILI9488 / RGB666 + SD demo~n")
    spi = :spi.open(@spi_config)
    :io.format(~c"SPI opened: ~p~n", [spi])

    # De-select other devices on the shared bus
    for pin <- [@pin_touch_cs, @pin_sd_cs] do
      :gpio.set_pin_mode(pin, :output)
      :gpio.digital_write(pin, :high)
    end

    TFT.initialize(spi)
    TFT.draw_sanity_bars(spi)

    case SD.mount(spi, @pin_sd_cs, @sd_root, @sd_driver) do
      {:ok, _mref} ->
        SD.print_directory(@sd_root)

        case SD.list_rgb_files(@sd_root) do
          [] ->
            :io.format(~c"No RAW RGB found (.RGB). Expect 480x320 at SD root.~n")

          [first_path | _] ->
            display_blit_raw_rgb_file(spi, first_path, {@panel_w, @panel_h})
        end

        Process.sleep(:infinity)

      {:error, _} ->
        Process.sleep(:infinity)
    end
  end

  # One address window + single RAMWR, then stream SD bytes to SPI
  # Only supports RGB565 (2 B/px) and 3-byte RGB (treated as RGB666/888).
  defp display_blit_raw_rgb_file(spi, path, {width, height}) do
    pixels = width * height

    bpp =
      case SD.file_size(path, @sd_chunk_bytes) do
        {:ok, size} when rem(size, pixels) == 0 -> div(size, pixels)
        _ -> :unknown
      end

    :io.format(~c"Blit ~s as ~p x ~p, detected bpp: ~p~n", [path, width, height, bpp])

    TFT.set_window(spi, {0, 0}, {width - 1, height - 1})
    TFT.begin_ram_write(spi)

    case bpp do
      2 ->
        # RGB565 (assumed little-endian) → expand to 3 bytes/pixel for ILI9488 (18-bit mode)
        SD.stream_file_chunks(path, @sd_chunk_bytes, fn bin ->
          :ok =
            :spi.write(spi, TFT.spi_device(), %{write_data: convert_chunk_rgb565le_to_rgb888(bin)})
        end)

      3 ->
        # 3-byte RGB (RGB666/888) → stream as-is (ILI9488 uses top 6 bits)
        SD.stream_file_chunks(path, @sd_chunk_bytes, fn bin ->
          :ok = :spi.write(spi, TFT.spi_device(), %{write_data: bin})
        end)

      _ ->
        :io.format(
          ~c"Unsupported file size. Only RGB565 (2 B/px) and RGB666 (3 B/px) are supported.~n"
        )
    end

    :io.format(~c"Blit done.~n")
  end

  # Convert a chunk of RGB565 (little-endian) to 3-byte RGB.
  # For each 16-bit word (lo,hi):
  #   r5 = bits 11..15, g6 = bits 5..10, b5 = bits 0..4
  #   r8 = (r5<<3)|(r5>>2), g8 = (g6<<2)|(g6>>4), b8 = (b5<<3)|(b5>>2)
  defp convert_chunk_rgb565le_to_rgb888(bin), do: conv565le(bin, <<>>)
  defp conv565le(<<>>, acc), do: acc

  # Process two bytes at a time; @sd_chunk_bytes is even so we don't need carry-over.
  defp conv565le(<<lo, hi, rest::binary>>, acc) do
    val = bor(lo, bsl(hi, 8))
    r5 = band(bsr(val, 11), 0x1F)
    g6 = band(bsr(val, 5), 0x3F)
    b5 = band(val, 0x1F)

    r8 = bor(bsl(r5, 3), bsr(r5, 2))
    g8 = bor(bsl(g6, 2), bsr(g6, 4))
    b8 = bor(bsl(b5, 3), bsr(b5, 2))

    conv565le(rest, <<acc::binary, r8, g8, b8>>)
  end
end
