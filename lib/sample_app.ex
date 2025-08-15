defmodule SampleApp do
  @moduledoc """
  ILI9488 (SPI, RGB666/18-bit) + SD RAW RGB666 blit (AtomVM on XIAO-ESP32S3).

  Flow:
    1) Init TFT (same sequence that drew bars before)
    2) Draw sanity bars + red square
    3) Mount SD at /sdcard, list entries
    4) Pick a RAW RGB666 file (RGB order) and blit it line-by-line (1 write per row)

  Expectation:
    - Files are RGB triplets (R,G,B), 3 bytes/pixel, top-left origin, 480x320 (or 320x480).
    - If name contains "480x320" or "320x480", we use that; otherwise default 480x320.
  """

  import Bitwise

  # ── SPI mapping (known-good) ────────────────────────────────────────────────
  @spi_config [
    bus_config: [
      # D8 → GPIO7
      sclk: 7,
      # D9 → GPIO8
      miso: 8,
      # D10 → GPIO9
      mosi: 9
    ],
    device_config: [
      spi_dev_tft: [
        # D6/TX → GPIO43 (TFT CS)
        cs: 43,
        mode: 0,
        clock_speed_hz: 20_000_000,
        command_len_bits: 0,
        address_len_bits: 0
      ]
    ]
  ]

  # ── Pins ────────────────────────────────────────────────────────────────────
  # D2 → GPIO3
  @pin_tft_dc 3
  # D1 → GPIO2
  @pin_tft_rst 2
  # D7 → GPIO44 (keep HIGH)
  @pin_touch_cs 44
  # D3 → GPIO4  (SD CS)
  @pin_sd_cs 4

  @mount ~c"/sdcard"

  # ── ILI9488 / MIPI DCS ──────────────────────────────────────────────────────
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

  # Landscape + BGR bit set → we can send <<R,G,B>> naturally
  @madctl_landscape_bgr 0x28
  # RGB666
  @pixfmt_18bit 0x66

  # ── Tunables ────────────────────────────────────────────────────────────────
  # for solid fills
  @rgb666_chunk_px 128
  # SD read chunk size (bytes)
  @file_read_chunk 2048

  # ── Entry ──────────────────────────────────────────────────────────────────
  def start() do
    :io.format(~c"ILI9488 / RGB666 bring-up + SD RAW666 demo~n", [])
    spi = :spi.open(@spi_config)
    :io.format(~c"SPI opened: ~p~n", [spi])

    # Deselect other SPI devices
    for pin <- [@pin_touch_cs, @pin_sd_cs] do
      :gpio.set_pin_mode(pin, :output)
      :gpio.digital_write(pin, :high)
    end

    :gpio.set_pin_mode(@pin_tft_dc, :output)
    :gpio.set_pin_mode(@pin_tft_rst, :output)

    # --- TFT init (proven-good sequence) ---
    panel_hard_reset()
    cmd(spi, @cmd_slpout)
    Process.sleep(150)
    cmd(spi, @cmd_noron)
    Process.sleep(10)
    cmd(spi, @cmd_madctl)
    data(spi, @madctl_landscape_bgr)
    cmd(spi, @cmd_pixfmt)
    data(spi, @pixfmt_18bit)
    cmd(spi, @cmd_dispon)
    Process.sleep(20)

    # Visible heartbeat
    cmd(spi, @cmd_invon)
    Process.sleep(120)
    cmd(spi, @cmd_invoff)
    Process.sleep(120)

    # --- Sanity: bars + a red rectangle ---
    fill_rect_rgb666(spi, 0, 0, 160, 320, rgb888_to_rgb666(236, 238, 159))
    fill_rect_rgb666(spi, 160, 0, 160, 320, rgb888_to_rgb666(182, 234, 181))
    fill_rect_rgb666(spi, 320, 0, 160, 320, rgb888_to_rgb666(183, 207, 255))
    fill_rect_rgb666(spi, 160, 100, 160, 120, rgb888_to_rgb666(255, 0, 0))
    :io.format(~c"TFT self-test done (bars + red rect).~n", [])

    # --- SD mount + list ---
    case :esp.mount(~c"sdspi", @mount, :fat, [{:spi_host, spi}, {:cs, @pin_sd_cs}]) do
      {:ok, mref} ->
        _holder = spawn(fn -> hold(mref) end)

        list_once(@mount)

        case pick_first_raw666(@mount) do
          {:ok, path, {w, h}} ->
            blit_raw666(spi, path, w, h)

          :none ->
            :io.format(~c"No RAW666 file found. Expect 480x320 .RGB/.RGB666 at SD root.~n", [])
        end

        Process.sleep(:infinity)

      {:error, r} ->
        :io.format(~c"SD mount failed: ~p~n", [r])
        Process.sleep(:infinity)
    end
  end

  # ── SPI helpers ────────────────────────────────────────────────────────────
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

  defp data_stream(spi, chunks) do
    :gpio.digital_write(@pin_tft_dc, :high)

    Enum.each(chunks, fn ch ->
      bin = if is_binary(ch), do: ch, else: IO.iodata_to_binary(ch)
      :spi.write(spi, :spi_dev_tft, %{write_data: bin, write_bits: byte_size(bin) * 8})
    end)
  end

  # ── RGB666 drawing (bars / solids) ─────────────────────────────────────────
  defp rgb888_to_rgb666(r8, g8, b8), do: {r8 &&& 0xFC, g8 &&& 0xFC, b8 &&& 0xFC}

  defp fill_rect_rgb666(spi, x, y, w, h, {r, g, b}) do
    set_window(spi, x, y, x + w - 1, y + h - 1)
    total_pixels = w * h
    chunk = :binary.copy(<<r, g, b>>, @rgb666_chunk_px)

    cmd(spi, @cmd_ramwr)

    full = div(total_pixels, @rgb666_chunk_px)
    remp = rem(total_pixels, @rgb666_chunk_px)

    full > 0 && data_stream(spi, List.duplicate(chunk, full))
    if remp > 0, do: data(spi, :binary.copy(<<r, g, b>>, remp))
  end

  defp set_window(spi, x0, y0, x1, y1) do
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

  # ── SD / dir listing helpers ───────────────────────────────────────────────
  defp hold(mref),
    do:
      (
        _ = mref

        receive do
        after
          86_400_000 -> hold(mref)
        end
      )

  defp list_once(path) do
    :io.format(~c"Listing ~s~n", [path])

    case :atomvm.posix_opendir(path) do
      {:ok, dir} ->
        list_loop(dir)
        :atomvm.posix_closedir(dir)

      {:error, r} ->
        :io.format(~c"opendir(~s) failed: ~p~n", [path, r])
    end
  end

  defp list_loop(dir) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name_any}} ->
        n = to_list(name_any)
        if n != [], do: :io.format(~c"  - ~s~n", [n])
        list_loop(dir)

      :eof ->
        :ok

      {:error, r} ->
        :io.format(~c"readdir error: ~p~n", [r])

      _ ->
        :ok
    end
  end

  defp to_list(x) when is_list(x), do: x
  defp to_list(x) when is_binary(x), do: :erlang.binary_to_list(x)
  defp to_list(x), do: x

  # ── File picking (find .RGB / .RGB666; prefer names with “480x320”) ────────
  defp pick_first_raw666(base) do
    files = find_rgb666_files(base)

    case files do
      [] ->
        :none

      _ ->
        case Enum.find(files, &has_sub(&1, ~c"480x320")) do
          nil ->
            case Enum.find(files, &has_sub(&1, ~c"320x480")) do
              nil -> {:ok, hd(files), {480, 320}}
              path2 -> {:ok, path2, {320, 480}}
            end

          path ->
            {:ok, path, {480, 320}}
        end
    end
  end

  defp find_rgb666_files(base) do
    case :atomvm.posix_opendir(base) do
      {:ok, dir} ->
        acc = collect_rgb666(dir, base, [])
        :atomvm.posix_closedir(dir)
        :lists.sort(acc)

      _ ->
        []
    end
  end

  defp collect_rgb666(dir, base, acc) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name_any}} ->
        name = to_list(name_any)
        acc2 = if name != [] and ends_with_rgb666(name), do: [join(base, name) | acc], else: acc
        collect_rgb666(dir, base, acc2)

      :eof ->
        acc

      _ ->
        acc
    end
  end

  defp ends_with_rgb666(name_cs) do
    r = :lists.reverse(name_cs)

    case r do
      # .RGB / .rgb
      [?B, ?G, ?R, ?. | _] -> true
      [?b, ?g, ?r, ?. | _] -> true
      # .RGB666 / .rgb666
      [?6, ?6, ?6, ?B, ?G, ?R, ?. | _] -> true
      [?6, ?6, ?6, ?b, ?g, ?r, ?. | _] -> true
      _ -> false
    end
  end

  defp has_sub(hay, needle), do: has_sub_loop(hay, needle)
  defp has_sub_loop(_, []), do: true
  defp has_sub_loop([], _), do: false
  defp has_sub_loop([h | t], [h | tn]), do: has_sub_loop(t, tn)
  defp has_sub_loop([_ | t], n), do: has_sub_loop(t, n)

  defp join(base, rel_any) do
    rel = to_list(rel_any)
    sep = if base != [] and last_(base) == ?/, do: [], else: [?/]

    rr =
      case rel do
        [?/ | rest] -> rest
        _ -> rel
      end

    base ++ sep ++ rr
  end

  defp last_([h]), do: h
  defp last_([_ | t]), do: last_(t)

  # ── RAW RGB666 (RGB order), 1 write per row ────────────────────────────────
  defp blit_raw666(spi, path, w, h) do
    row_bytes = w * 3
    :io.format(~c"Blit RAW666 (line/row) ~s as ~p x ~p~n", [path, w, h])

    case :atomvm.posix_open(path, [:o_rdonly]) do
      {:ok, fd} ->
        for y <- 0..(h - 1) do
          case read_exact(fd, row_bytes, <<>>) do
            {:ok, row} ->
              set_window(spi, 0, y, w - 1, y)
              cmd(spi, @cmd_ramwr)
              :gpio.digital_write(@pin_tft_dc, :high)
              :spi.write(spi, :spi_dev_tft, %{write_data: row, write_bits: row_bytes * 8})

            :eof ->
              :io.format(~c"EOF @ row ~p~n", [y])
              :atomvm.posix_close(fd)
              return_ok()

            {:error, r} ->
              :io.format(~c"read error @ row ~p: ~p~n", [y, r])
              :atomvm.posix_close(fd)
              return_ok()
          end
        end

        :atomvm.posix_close(fd)
        :io.format(~c"Blit done.~n", [])
        :ok

      {:error, r} ->
        :io.format(~c"open failed: ~p~n", [r])
        :ok
    end
  end

  # Read exactly N bytes (or report :eof / :error)
  defp read_exact(_fd, 0, acc), do: {:ok, acc}

  defp read_exact(fd, left, acc) when left > 0 do
    to_read = if left < @file_read_chunk, do: left, else: @file_read_chunk

    case :atomvm.posix_read(fd, to_read) do
      {:ok, bin} when is_binary(bin) and bin != <<>> ->
        read_exact(fd, left - byte_size(bin), <<acc::binary, bin::binary>>)

      :eof ->
        :eof

      {:error, r} ->
        {:error, r}

      _ ->
        {:error, :unknown}
    end
  end

  defp return_ok(), do: :ok
end
