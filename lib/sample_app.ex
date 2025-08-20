defmodule SampleApp do
  @moduledoc """
  ILI9488 over SPI (RGB666/18-bit) with SD card (FAT) image blitting and a clock overlay.
  Touch support: emits {:touch, x, y, z} and paints a small green dot per event.

  Target: Seeed XIAO-ESP32S3 running AtomVM.

  Boot:
    1) Initialize display
    2) Draw quick color bars
    3) Mount /sdcard and list files
    4) Blit the first .RGB file as full screen (expects 3 bytes/pixel, top-left origin)
    5) Start HH:MM:SS clock
    6) Start touch reader and handle events
  """

  alias SampleApp.TFT
  alias SampleApp.SD
  alias SampleApp.Clock
  alias SampleApp.Touch

  # ── SPI wiring (XIAO: D8→GPIO7, D9→GPIO8, D10→GPIO9; TFT CS on GPIO43) ──────────
  @spi_config [
    bus_config: [sclk: 7, miso: 8, mosi: 9],
    device_config: [
      spi_dev_tft: [
        cs: 43,
        mode: 0,
        clock_speed_hz: 20_000_000,
        command_len_bits: 0,
        address_len_bits: 0
      ],
      spi_dev_touch: [
        cs: 44,
        mode: 0,
        clock_speed_hz: 1_000_000,
        command_len_bits: 0,
        address_len_bits: 0
      ]
    ]
  ]

  # Shared bus chip selects (keep HIGH when idle)
  # D7  Touch CS (GPIO44)
  @pin_touch_cs 44
  # D3  SD CS (GPIO4)
  @pin_sd_cs 4

  # SD mount
  @sd_driver ~c"sdspi"
  @sd_root ~c"/sdcard"

  # Fallback priv image (project app atom, filename in priv/)
  @priv_app :sample_app
  @priv_fallback ~c"default.rgb"

  # ── Entry ───────────────────────────────────────────────────────────────────────
  def start() do
    :io.format(~c"ILI9488 / RGB24 (RGB666 panel) + SD + Touch demo~n")
    spi = :spi.open(@spi_config)
    :io.format(~c"SPI opened: ~p~n", [spi])

    # De-select SD on the shared bus (touch/tft CS are controlled by the SPI device)
    for pin <- [@pin_sd_cs] do
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
            :io.format(~c"No .RGB found on SD. Falling back to priv/~s~n", [@priv_fallback])
            blit_fullscreen_rgb24_from_priv(spi, @priv_app, @priv_fallback)

          [first_path | _] ->
            blit_fullscreen_rgb24_from_sd(spi, first_path)
        end

      {:error, reason} ->
        :io.format(~c"SD mount failed (~p). Falling back to priv/~s~n", [reason, @priv_fallback])
        blit_fullscreen_rgb24_from_priv(spi, @priv_app, @priv_fallback)
    end

    # Start the HH:MM:SS overlay (top center)
    {:ok, _clock_pid} = Clock.start_link(spi, h_align: :center, y: 5)

    # Start touch reader; send events to this process
    {:ok, _touch_pid} = Touch.start_link(spi, notify: self())

    # Example event handler: draw a tiny green dot per touch event
    spawn_link(fn -> touch_event_loop(spi) end)

    Process.sleep(:infinity)
  end

  defp touch_event_loop(spi) do
    receive do
      {:touch, x, y, _z} ->
        # a tiny 3x3 dot; color is bright green (RGB666-ish)
        TFT.fill_rect_rgb666(spi, {max(x - 1, 0), max(y - 1, 0)}, {3, 3}, {0x00, 0xFC, 0x00})
        touch_event_loop(spi)

      _other ->
        touch_event_loop(spi)
    end
  end

  # ── Blit helpers (RGB24 only) ───────────────────────────────────────────────────

  defp blit_fullscreen_rgb24_from_sd(spi, path) do
    width = TFT.width()
    height = TFT.height()
    pixels = width * height
    need = pixels * 3
    chunk = TFT.max_chunk_bytes()

    size =
      case SD.file_size(path, chunk) do
        {:ok, s} -> s
        _ -> -1
      end

    if size != need do
      :io.format(
        ~c"[SD] ~s: size ~p does not match expected ~p (W×H×3). Skipping.~n",
        [path, size, need]
      )

      :error
    else
      :io.format(~c"[SD] Blit ~s as ~p x ~p (RGB24)~n", [path, width, height])

      TFT.with_lock(fn ->
        TFT.set_window(spi, {0, 0}, {width - 1, height - 1})
        TFT.begin_ram_write(spi)
        SD.stream_file_chunks(path, chunk, fn bin -> TFT.spi_write_chunks(spi, bin) end)
      end)

      :io.format(~c"[SD] Blit done.~n")
      :ok
    end
  end

  defp blit_fullscreen_rgb24_from_priv(spi, app_atom, filename) do
    width = TFT.width()
    height = TFT.height()
    pixels = width * height
    need = pixels * 3

    case :atomvm.read_priv(app_atom, filename) do
      bin when is_binary(bin) and byte_size(bin) == need ->
        :io.format(~c"[priv] Blit ~s as ~p x ~p (RGB24)~n", [filename, width, height])

        TFT.with_lock(fn ->
          TFT.set_window(spi, {0, 0}, {width - 1, height - 1})
          TFT.begin_ram_write(spi)
          TFT.spi_write_chunks(spi, bin)
        end)

        :io.format(~c"[priv] Blit done.~n")
        :ok

      bin when is_binary(bin) ->
        :io.format(
          ~c"[priv] ~s size ~p does not match expected ~p (W×H×3). Skipping.~n",
          [filename, byte_size(bin), need]
        )

        :error

      other ->
        :io.format(~c"[priv] Could not read ~s (got ~p).~n", [filename, other])
        :error
    end
  end
end
