defmodule SampleApp do
  @moduledoc """
  Minimal ILI9488 (SPI, RGB666 / 18-bit) bring-up on Seeed XIAO ESP32-S3 via AtomVM.
  """

  import Bitwise

  # ─────────────────────────────────────────────────────────────────────────────
  # Pin map 
  # ─────────────────────────────────────────────────────────────────────────────

  @spi_config [
    bus_config: [
      # D8  → GPIO7
      sclk: 7,
      # D9  → GPIO8
      miso: 8,
      # D10 → GPIO9
      mosi: 9
    ],
    device_config: [
      spi_dev_tft: [
        # D6/TX → GPIO43
        cs: 43,
        mode: 0,
        clock_speed_hz: 20_000_000,
        command_len_bits: 0,
        address_len_bits: 0
      ]
    ]
  ]

  # D2    → GPIO3
  @pin_tft_dc 3
  # D1    → GPIO2
  @pin_tft_rst 2
  # D3    → GPIO4
  @pin_tft_bl 4

  # Touch controller (keep inactive)
  # D7 → GPIO44  (hold HIGH)
  @pin_touch_cs 44

  # Chunk size: small, DMA-friendly on ESP32-S3 (RGB666 → 3 bytes/pixel) 
  # 128 px × 3 bytes = 384 bytes/transfer 
  @rgb666_chunk_px 128

  # ─────────────────────────────────────────────────────────────────────────────
  # MIPI DCS / ILI9488 commands
  # ─────────────────────────────────────────────────────────────────────────────
  @cmd_slpout 0x11
  @cmd_noron 0x13
  @cmd_dispon 0x29
  @cmd_madctl 0x36
  @cmd_pixfmt 0x3A
  @cmd_caset 0x2A
  @cmd_paset 0x2B
  @cmd_ramwr 0x2C
  @cmd_invoff 0x20
  @cmd_invon 0x21

  # Orientation & color order:
  #   0x20 = MV (rotate)
  #   0x08 = BGR bit
  # We use MV+BGR so payloads can be <<r,g,b>> without swapping.
  @madctl_mv_bgr 0x28
  @pixfmt_18bit 0x66

  # ─────────────────────────────────────────────────────────────────────────────
  # Entry point
  # ─────────────────────────────────────────────────────────────────────────────

  def start() do
    :io.format(~c"ILI9488 / RGB666 bring-up~n", [])

    # Open SPI (note: :spi.open/1 returns a PID, not {:ok, pid})
    spi = :spi.open(@spi_config)

    :io.format(~c"SPI opened: ~p~n", [spi])

    # Keep touch deselected so it releases MISO; power backlight if gated
    gpio_config_output(@pin_touch_cs, :high, ~c"T_CS HIGH (touch deselect)")
    # flip to :low if active-low
    gpio_config_output(@pin_tft_bl, :high, ~c"BL HIGH (backlight on)")

    # DC / RST as outputs
    :gpio.set_pin_mode(@pin_tft_dc, :output)
    :gpio.set_pin_mode(@pin_tft_rst, :output)

    # Panel hardware reset
    panel_hard_reset()

    # Minimal, stable init for ILI9488
    cmd(spi, @cmd_slpout)
    Process.sleep(150)
    cmd(spi, @cmd_noron)
    Process.sleep(10)
    # MV + BGR
    cmd(spi, @cmd_madctl)
    data(spi, @madctl_mv_bgr)
    # 18-bit
    cmd(spi, @cmd_pixfmt)
    data(spi, @pixfmt_18bit)
    cmd(spi, @cmd_dispon)
    Process.sleep(20)

    # Visible heartbeat (prove commands reached)
    cmd(spi, @cmd_invon)
    Process.sleep(120)
    cmd(spi, @cmd_invoff)
    Process.sleep(120)

    # Demo: RGB test bars + a small red rectangle
    fill_rect_rgb666(spi, 0, 0, 160, 320, rgb888_to_rgb666(236, 238, 159))
    fill_rect_rgb666(spi, 160, 0, 160, 320, rgb888_to_rgb666(182, 234, 181))
    fill_rect_rgb666(spi, 320, 0, 160, 320, rgb888_to_rgb666(183, 207, 255))
    fill_rect_rgb666(spi, 160, 100, 160, 120, rgb888_to_rgb666(255, 0, 0))

    :io.format(~c"Demo done.~n", [])

    # Keep app alive so screen stays up
    Process.sleep(:infinity)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Unified SPI senders
  # ─────────────────────────────────────────────────────────────────────────────

  # Generic sender with DC control. Accepts int, binary, or iodata.
  defp spi_send(spi, payload, kind) when kind in [:cmd, :data] do
    bin =
      cond do
        is_integer(payload) -> <<payload &&& 0xFF>>
        is_binary(payload) -> payload
        is_list(payload) -> IO.iodata_to_binary(payload)
      end

    :gpio.digital_write(@pin_tft_dc, if(kind == :data, do: :high, else: :low))
    :spi.write(spi, :spi_dev_tft, %{write_data: bin, write_bits: byte_size(bin) * 8})
  end

  defp cmd(spi, bytes), do: spi_send(spi, bytes, :cmd)
  defp data(spi, bytes), do: spi_send(spi, bytes, :data)

  # For big pixel floods: avoid toggling DC per chunk
  defp data_stream(spi, chunks) do
    :gpio.digital_write(@pin_tft_dc, :high)

    Enum.each(chunks, fn ch ->
      bin = if is_binary(ch), do: ch, else: IO.iodata_to_binary(ch)
      :spi.write(spi, :spi_dev_tft, %{write_data: bin, write_bits: byte_size(bin) * 8})
    end)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # High-level drawing (RGB666 only)
  # ─────────────────────────────────────────────────────────────────────────────

  @doc "Convert 8-bit RGB to 6-bit-aligned RGB666 (each channel multiple of 4)."
  defp rgb888_to_rgb666(r8, g8, b8), do: {r8 &&& 0xFC, g8 &&& 0xFC, b8 &&& 0xFC}

  @doc "Fill a rectangle with a solid RGB666 color using chunked SPI transfers."
  defp fill_rect_rgb666(spi, x, y, w, h, {r, g, b}) do
    set_drawing_window(spi, x, y, x + w - 1, y + h - 1)

    total_pixels = w * h
    chunk = :binary.copy(<<r, g, b>>, @rgb666_chunk_px)

    # Start pixel write phase
    cmd(spi, @cmd_ramwr)

    # Stream full chunks
    full = div(total_pixels, @rgb666_chunk_px)
    remp = rem(total_pixels, @rgb666_chunk_px)

    full > 0 && data_stream(spi, List.duplicate(chunk, full))

    # Tail
    if remp > 0 do
      data(spi, :binary.copy(<<r, g, b>>, remp))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DCS helpers (window + reset + GPIO)
  # ─────────────────────────────────────────────────────────────────────────────

  defp set_drawing_window(spi, x0, y0, x1, y1) do
    cmd(spi, @cmd_caset)
    data(spi, [x0 >>> 8 &&& 0xFF, x0 &&& 0xFF, x1 >>> 8 &&& 0xFF, x1 &&& 0xFF])

    cmd(spi, @cmd_paset)
    data(spi, [y0 >>> 8 &&& 0xFF, y0 &&& 0xFF, y1 >>> 8 &&& 0xFF, y1 &&& 0xFF])
  end

  defp panel_hard_reset() do
    :gpio.digital_write(@pin_tft_rst, :high)
    Process.sleep(10)
    :gpio.digital_write(@pin_tft_rst, :low)
    Process.sleep(80)
    :gpio.digital_write(@pin_tft_rst, :high)
    Process.sleep(150)
  end

  defp gpio_config_output(pin, level, label_charlist) do
    :gpio.set_pin_mode(pin, :output)
    :gpio.digital_write(pin, level)
    :io.format(~c"~s~n", [label_charlist])
  end
end
