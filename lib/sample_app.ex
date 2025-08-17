defmodule SampleApp do
  @moduledoc """
  ILI9488 over SPI (RGB666/18-bit) with SD card (FAT) image blitting.
  Target: Seeed XIAO-ESP32S3 on AtomVM.

  Boot sequence:
    1) Initialize the display (MIPI DCS over SPI)
    2) Draw quick color bars (sanity check)
    3) Mount /sdcard and list files
    4) Blit the first .RGB/.RGB666 file as 480×320 (RGB order, 3 bytes/pixel)
  """

  import Bitwise

  # ── SPI wiring (XIAO: D8→GPIO7, D9→GPIO8, D10→GPIO9; TFT CS on GPIO43) ────────
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

  # Control pins (XIAO silkscreen → GPIO)
  # D2  Display D/C
  @pin_dc 3
  # D1  Display RESET
  @pin_rst 2
  # D7  Touch CS (kept HIGH)
  @pin_touch_cs 44
  # D3  SD CS
  @pin_sd_cs 4

  # SD mount
  @sd_driver ~c"sdspi"
  @sd_root ~c"/sdcard"

  # MIPI DCS command bytes used here
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

  # Display format/orientation (landscape, BGR bit set so <<R,G,B>> looks right)
  @madctl_landscape_bgr 0x28
  # 18-bit; still send 3 bytes/pixel
  @pixfmt_rgb666 0x66

  # ── Transfer chunking ─────────────────────────────────────────────────────────
  @bytes_per_pixel_rgb666 3
  @dma_alignment_bytes 4
  @target_chunk_bytes 4 * 1024
  # 4092
  @spi_write_chunk_bytes @target_chunk_bytes -
                           rem(
                             @target_chunk_bytes,
                             @bytes_per_pixel_rgb666 * @dma_alignment_bytes
                           )
  @spi_write_chunk_pixels div(@spi_write_chunk_bytes, @bytes_per_pixel_rgb666)
  @sd_chunk_bytes @spi_write_chunk_bytes

  # Panel geometry
  @panel_w 480
  @panel_h 320

  # ── Entry point ───────────────────────────────────────────────────────────────
  def start() do
    :io.format(~c"ILI9488 / RGB666 + SD demo~n")
    spi = :spi.open(@spi_config)
    :io.format(~c"SPI opened: ~p~n", [spi])

    # de-select other devices on the shared bus
    for pin <- [@pin_touch_cs, @pin_sd_cs] do
      :gpio.set_pin_mode(pin, :output)
      :gpio.digital_write(pin, :high)
    end

    for pin <- [@pin_dc, @pin_rst], do: :gpio.set_pin_mode(pin, :output)

    display_initialize(spi)
    display_draw_sanity_bars(spi)

    case :esp.mount(@sd_driver, @sd_root, :fat, spi_host: spi, cs: @pin_sd_cs) do
      {:ok, mref} ->
        _keep = spawn_link(fn -> keep_mount_alive(mref) end)

        sd_card_print_directory(@sd_root)

        case sd_card_list_rgb666_files(@sd_root) do
          [] ->
            :io.format(~c"No RAW RGB666 found (.RGB/.RGB666). Expect 480x320 at SD root.~n")

          [first_path | _] ->
            display_blit_rgb666_file(spi, first_path, {@panel_w, @panel_h})
        end

        Process.sleep(:infinity)

      {:error, reason} ->
        :io.format(~c"SD mount failed: ~p~n", [reason])
        Process.sleep(:infinity)
    end
  end

  # ── Display helpers ───────────────────────────────────────────────────────────

  defp display_initialize(spi) do
    display_hardware_reset()

    display_send_command(spi, @cmd_slpout)
    Process.sleep(150)
    display_send_command(spi, @cmd_noron)
    Process.sleep(10)
    display_send_command(spi, @cmd_madctl)
    display_send_data(spi, <<@madctl_landscape_bgr>>)
    display_send_command(spi, @cmd_pixfmt)
    display_send_data(spi, <<@pixfmt_rgb666>>)
    display_send_command(spi, @cmd_dispon)
    Process.sleep(20)

    # quick visible heartbeat
    display_send_command(spi, @cmd_invon)
    Process.sleep(120)
    display_send_command(spi, @cmd_invoff)
    Process.sleep(120)
  end

  defp display_draw_sanity_bars(spi) do
    display_fill_rect_rgb666(spi, {160, 100}, {40, 120}, rgb888_to_rgb666(255, 255, 255))
    display_fill_rect_rgb666(spi, {200, 100}, {40, 120}, rgb888_to_rgb666(255, 0, 0))
    display_fill_rect_rgb666(spi, {240, 100}, {40, 120}, rgb888_to_rgb666(0, 255, 0))
    display_fill_rect_rgb666(spi, {280, 100}, {40, 120}, rgb888_to_rgb666(0, 0, 255))
    :io.format(~c"Display self-test done (bars).~n")
  end

  # Convert 8-bit/channel RGB to RGB666-compatible bytes (panel ignores low 2 bits)
  defp rgb888_to_rgb666(r8, g8, b8), do: {r8 &&& 0xFC, g8 &&& 0xFC, b8 &&& 0xFC}

  # Solid fill via single RAMWR + chunked payloads
  defp display_fill_rect_rgb666(spi, {x, y}, {w, h}, {r, g, b}) do
    display_set_address_window(spi, {x, y}, {x + w - 1, y + h - 1})

    total_pixels = w * h
    chunk_px = @spi_write_chunk_pixels
    chunk = :binary.copy(<<r, g, b>>, chunk_px)

    display_send_command(spi, @cmd_ramwr)
    set_dc_for_data()

    full = div(total_pixels, chunk_px)
    remp = rem(total_pixels, chunk_px)

    for _ <- 1..full, do: :ok = :spi.write(spi, :spi_dev_tft, %{write_data: chunk})

    if remp > 0,
      do: :ok = :spi.write(spi, :spi_dev_tft, %{write_data: :binary.copy(<<r, g, b>>, remp)})
  end

  # Address window (CASET/PASET)
  defp display_set_address_window(spi, {x0, y0}, {x1, y1}) do
    display_send_command(spi, @cmd_caset)
    display_send_data(spi, <<x0::16-big, x1::16-big>>)
    display_send_command(spi, @cmd_paset)
    display_send_data(spi, <<y0::16-big, y1::16-big>>)
  end

  # Low-level DCS writes (toggle D/C then send)
  defp display_send_command(spi, byte) when is_integer(byte) and byte in 0..255 do
    set_dc_for_command()
    :ok = :spi.write(spi, :spi_dev_tft, %{write_data: <<byte>>})
  end

  defp display_send_data(spi, bin) when is_binary(bin) do
    set_dc_for_data()
    :ok = :spi.write(spi, :spi_dev_tft, %{write_data: bin})
  end

  # D/C pin
  defp set_dc_for_command(), do: :gpio.digital_write(@pin_dc, :low)
  defp set_dc_for_data(), do: :gpio.digital_write(@pin_dc, :high)

  # Hardware reset timing common to ILI948x boards
  defp display_hardware_reset() do
    :gpio.digital_write(@pin_rst, :high)
    Process.sleep(10)
    :gpio.digital_write(@pin_rst, :low)
    Process.sleep(80)
    :gpio.digital_write(@pin_rst, :high)
    Process.sleep(150)
  end

  # ── SD card utilities (AtomVM-safe) ───────────────────────────────────────────

  defp sd_card_print_directory(path) do
    :io.format(~c"Listing ~s~n", [path])

    case :atomvm.posix_opendir(path) do
      {:ok, dir} ->
        sd_card_print_directory_entries(dir)
        :atomvm.posix_closedir(dir)

      {:error, r} ->
        :io.format(~c"opendir(~s) failed: ~p~n", [path, r])
    end
  end

  defp sd_card_print_directory_entries(dir) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name_any}} ->
        name = to_charlist_if_needed(name_any)
        if name != [], do: :io.format(~c"  - ~s~n", [name])
        sd_card_print_directory_entries(dir)

      :eof ->
        :ok

      {:error, r} ->
        :io.format(~c"readdir error: ~p~n", [r])

      _ ->
        :ok
    end
  end

  # Sorted list of files ending in .RGB / .RGB666 at the given base path
  defp sd_card_list_rgb666_files(base) do
    names = sd_card_list_entry_names(base)
    matches = :lists.filter(fn name -> has_rgb666_extension?(name) end, names)
    paths = :lists.map(fn name -> path_join(base, name) end, matches)
    :lists.sort(paths)
  end

  defp sd_card_list_entry_names(base) do
    case :atomvm.posix_opendir(base) do
      {:ok, dir} ->
        names = sd_card_collect_entry_names(dir, [])
        :atomvm.posix_closedir(dir)
        names

      _ ->
        []
    end
  end

  defp sd_card_collect_entry_names(dir, acc) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name_any}} ->
        name = to_charlist_if_needed(name_any)
        acc2 = if name != [], do: [name | acc], else: acc
        sd_card_collect_entry_names(dir, acc2)

      :eof ->
        :lists.reverse(acc)

      _ ->
        :lists.reverse(acc)
    end
  end

  # ── Blitting (single window + continuous RAMWR) ───────────────────────────────

  defp display_blit_rgb666_file(spi, path, {width, height}) do
    :io.format(~c"[FAST] Blit ~s as ~p x ~p (~p bytes)~n", [
      path,
      width,
      height,
      width * height * 3
    ])

    case :atomvm.posix_open(path, [:o_rdonly]) do
      {:ok, fd} ->
        display_set_address_window(spi, {0, 0}, {width - 1, height - 1})
        display_send_command(spi, @cmd_ramwr)
        set_dc_for_data()

        _bytes = sd_card_stream_file_to_display(spi, fd, 0)

        :atomvm.posix_close(fd)
        :io.format(~c"Blit done.~n")

      {:error, r} ->
        :io.format(~c"open failed: ~p~n", [r])
    end
  end

  # Read SD in chunks and write each chunk to SPI immediately
  defp sd_card_stream_file_to_display(spi, fd, acc) do
    case :atomvm.posix_read(fd, @sd_chunk_bytes) do
      {:ok, bin} when is_binary(bin) and bin != <<>> ->
        :ok = :spi.write(spi, :spi_dev_tft, %{write_data: bin})
        sd_card_stream_file_to_display(spi, fd, acc + byte_size(bin))

      :eof ->
        acc

      {:error, r} ->
        :io.format(~c"read error: ~p~n", [r])
        acc

      _ ->
        acc
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp keep_mount_alive(mref) do
    _ = mref

    receive do
    after
      86_400_000 -> keep_mount_alive(mref)
    end
  end

  # Avoid Kernel.to_charlist/1 clash
  defp to_charlist_if_needed(x) when is_list(x), do: x
  defp to_charlist_if_needed(x) when is_binary(x), do: :erlang.binary_to_list(x)
  defp to_charlist_if_needed(x), do: x

  # Accept .RGB / .rgb / .RGB666 / .rgb666
  defp has_rgb666_extension?(name_cs) do
    case :lists.reverse(name_cs) do
      [?B, ?G, ?R, ?. | _] -> true
      [?b, ?g, ?r, ?. | _] -> true
      [?6, ?6, ?6, ?B, ?G, ?R, ?. | _] -> true
      [?6, ?6, ?6, ?b, ?g, ?r, ?. | _] -> true
      _ -> false
    end
  end

  defp path_join(base, rel_any) do
    rel = to_charlist_if_needed(rel_any)
    sep = if base != [] and last_char(base) == ?/, do: [], else: [?/]

    rr =
      case rel do
        [?/ | rest] -> rest
        _ -> rel
      end

    base ++ sep ++ rr
  end

  defp last_char([h]), do: h
  defp last_char([_ | t]), do: last_char(t)
end
