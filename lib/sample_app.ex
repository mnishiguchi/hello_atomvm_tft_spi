defmodule SampleApp do
  @moduledoc """
  ILI9488 over SPI (RGB666/18-bit) with SD card (FAT) image blitting.
  Target: Seeed XIAO-ESP32S3 running AtomVM.

  Boot:
    1) Initialize display
    2) Draw quick color bars
    3) Mount /sdcard and list files
    4) Blit the first .RGB file as panel-size (auto-detect RGB565 or 3-byte RGB by file size)
  """

  alias SampleApp.TFT
  alias SampleApp.SD
  alias SampleApp.Image

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
            :io.format(~c"No RAW RGB found (.RGB). Expect panel-sized image at SD root.~n")

          [first_path | _] ->
            blit_fullscreen_raw_rgb(spi, first_path)
        end

      {:error, error} ->
        :io.format(~c"SD mount failed: ~p~n", [error])
    end

    {:ok, _clock_pid} = SampleApp.Clock.start_link(spi, h_align: :center, y: 5)
    Process.sleep(:infinity)
  end

  # One address window + single RAMWR, then stream SD bytes to SPI
  # Supports RGB565 (2 B/px, little-endian) and 3-byte RGB.
  defp blit_fullscreen_raw_rgb(spi, path) do
    width = TFT.width()
    height = TFT.height()
    pixels = width * height
    chunk = TFT.max_chunk_bytes()

    bpp =
      case SD.file_size(path, chunk) do
        {:ok, size} -> Image.bpp_from_size(size, pixels)
        _ -> :unknown
      end

    :io.format(~c"Blit ~s as ~p x ~p, detected bpp: ~p~n", [path, width, height, bpp])

    TFT.set_window(spi, {0, 0}, {width - 1, height - 1})
    TFT.begin_ram_write(spi)

    case bpp do
      2 ->
        # RGB565 (little-endian) → expand to 3 bytes/pixel for ILI9488 (18-bit mode)
        SD.stream_file_chunks(path, chunk, fn bin ->
          TFT.spi_write_chunks(spi, Image.rgb565le_to_rgb888_chunk(bin))
        end)

      3 ->
        # 3-byte RGB (RGB666/888) → stream as-is (ILI9488 uses top 6 bits)
        SD.stream_file_chunks(path, chunk, fn bin ->
          TFT.spi_write_chunks(spi, bin)
        end)

      _ ->
        :io.format(
          ~c"Unsupported file size. Only RGB565 (2 B/px) and RGB666 (3 B/px) are supported.~n"
        )
    end

    :io.format(~c"Blit done.~n")
  end
end
