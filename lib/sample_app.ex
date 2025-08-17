defmodule SampleApp do
  @moduledoc """
  ILI9488 over SPI (RGB666/18-bit) with SD card (FAT) image blitting.
  Target: Seeed XIAO-ESP32S3 running AtomVM.

  Boot:
    1) Initialize display
    2) Draw quick color bars
    3) Mount /sdcard and list files
    4) Blit the first .RGB as 480×320 (RGB order, 3 bytes/pixel)
  """

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

        case SD.list_rgb666_files(@sd_root) do
          [] ->
            :io.format(~c"No RAW RGB666 found (.RGB). Expect 480x320 at SD root.~n")

          [first_path | _] ->
            display_blit_rgb666_file(spi, first_path, {@panel_w, @panel_h})
        end

        Process.sleep(:infinity)

      {:error, _} ->
        Process.sleep(:infinity)
    end
  end

  # One address window + single RAMWR, then stream SD bytes to SPI
  defp display_blit_rgb666_file(spi, path, {width, height}) do
    :io.format(~c"Blit ~s as ~p x ~p (~p bytes)~n", [path, width, height, width * height * 3])

    TFT.set_window(spi, {0, 0}, {width - 1, height - 1})
    TFT.begin_ram_write(spi)

    SD.stream_file_chunks(path, @sd_chunk_bytes, fn bin ->
      :ok = :spi.write(spi, TFT.spi_device(), %{write_data: bin})
    end)

    :io.format(~c"Blit done.~n")
  end
end
