defmodule SampleApp.TFT do
  @moduledoc """
  ILI9488 (SPI) helpers for AtomVM on XIAO-ESP32S3.
  """

  import Bitwise

  # --- Display geometry (exported) --------------------------------------------
  @screen_w 480
  @screen_h 320
  def width(), do: @screen_w
  def height(), do: @screen_h

  # Maximum safe write size for this host (bytes). 4092 avoids SPI driver error 258.
  @max_chunk_bytes 4092
  def max_chunk_bytes(), do: @max_chunk_bytes

  # --- SPI device name ---------------------------------------------------------
  @spi_dev :spi_dev_tft
  def spi_device(), do: @spi_dev

  # Control pins (XIAO silkscreen → GPIO)
  # D2: D/C
  @pin_dc 3
  # D1: RESET
  @pin_rst 2

  # MIPI DCS subset
  @cmd_slpout 0x11
  @cmd_noron 0x13
  @cmd_dispon 0x29
  @cmd_madctl 0x36
  @cmd_pixfmt 0x3A
  @cmd_caset 0x2A
  @cmd_paset 0x2B
  @cmd_ramwr 0x2C
  @cmd_invon 0x21
  @cmd_invoff 0x20

  # Orientation + pixel format
  @madctl_landscape_bgr 0x28
  # 18-bit; still 3 bytes/pixel
  @pixfmt_rgb666 0x66

  # Chunking for solid fills (~4 KiB; multiple of 12 for RGB666 + DMA)
  @bpp 3
  @dma_align 4
  @target 4 * 1024
  @spi_chunk_bytes @target - rem(@target, @bpp * @dma_align)
  @spi_chunk_px div(@spi_chunk_bytes, @bpp)

  # ── Public API ────────────────────────────────────────────────────────────────

  def initialize(spi) do
    :gpio.set_pin_mode(@pin_dc, :output)
    :gpio.set_pin_mode(@pin_rst, :output)

    hw_reset()

    send_command(spi, @cmd_slpout)
    Process.sleep(150)
    send_command(spi, @cmd_noron)
    Process.sleep(10)
    send_command(spi, @cmd_madctl)
    send_data(spi, <<@madctl_landscape_bgr>>)
    send_command(spi, @cmd_pixfmt)
    send_data(spi, <<@pixfmt_rgb666>>)
    send_command(spi, @cmd_dispon)
    Process.sleep(20)

    # quick “alive” blink
    send_command(spi, @cmd_invon)
    Process.sleep(120)
    send_command(spi, @cmd_invoff)
    Process.sleep(120)
    :ok
  end

  def draw_sanity_bars(spi) do
    fill_rect_rgb666(spi, {160, 100}, {40, 120}, rgb888_to_rgb666(255, 255, 255))
    fill_rect_rgb666(spi, {200, 100}, {40, 120}, rgb888_to_rgb666(255, 0, 0))
    fill_rect_rgb666(spi, {240, 100}, {40, 120}, rgb888_to_rgb666(0, 255, 0))
    fill_rect_rgb666(spi, {280, 100}, {40, 120}, rgb888_to_rgb666(0, 0, 255))
    :ok
  end

  # Convert 8-bit/channel to RGB666 bytes (panel ignores low 2 bits)
  def rgb888_to_rgb666(r8, g8, b8), do: {r8 &&& 0xFC, g8 &&& 0xFC, b8 &&& 0xFC}

  # Solid fill via single RAMWR + chunked payloads
  def fill_rect_rgb666(spi, {x, y}, {w, h}, {r, g, b}) do
    set_window(spi, {x, y}, {x + w - 1, y + h - 1})

    total_px = w * h
    chunk_px = @spi_chunk_px
    chunk = :binary.copy(<<r, g, b>>, chunk_px)

    begin_ram_write(spi)

    full = div(total_px, chunk_px)
    remp = rem(total_px, chunk_px)

    for _ <- 1..full, do: :ok = :spi.write(spi, @spi_dev, %{write_data: chunk})

    if remp > 0,
      do: :ok = :spi.write(spi, @spi_dev, %{write_data: :binary.copy(<<r, g, b>>, remp)})

    :ok
  end

  # Address window (CASET/PASET)
  def set_window(spi, {x0, y0}, {x1, y1}) do
    send_command(spi, @cmd_caset)
    send_data(spi, <<x0::16-big, x1::16-big>>)
    send_command(spi, @cmd_paset)
    send_data(spi, <<y0::16-big, y1::16-big>>)
    :ok
  end

  # One-time RAM write start, keep D/C = data for streaming
  def begin_ram_write(spi) do
    send_command(spi, @cmd_ramwr)
    set_dc_for_data()
    :ok
  end

  # ── Low-level ────────────────────────────────────────────────────────────────

  defp send_command(spi, byte) when is_integer(byte) and byte in 0..255 do
    set_dc_for_command()
    :ok = :spi.write(spi, @spi_dev, %{write_data: <<byte>>})
  end

  defp send_data(spi, bin) when is_binary(bin) do
    set_dc_for_data()
    :ok = :spi.write(spi, @spi_dev, %{write_data: bin})
  end

  defp set_dc_for_command(), do: :gpio.digital_write(@pin_dc, :low)
  defp set_dc_for_data(), do: :gpio.digital_write(@pin_dc, :high)

  defp hw_reset() do
    :gpio.digital_write(@pin_rst, :high)
    Process.sleep(10)
    :gpio.digital_write(@pin_rst, :low)
    Process.sleep(80)
    :gpio.digital_write(@pin_rst, :high)
    Process.sleep(150)
  end
end
