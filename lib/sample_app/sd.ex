defmodule SampleApp.SD do
  @moduledoc """
  SD card helpers for AtomVM (charlist paths).
  """

  alias SampleApp.Util

  # ── Mount / lifecycle ─────────────────────────────────────────────────────────

  @doc """
  Mount `driver` (default ~c"sdspi") at `root` using the given SPI host and CS pin.

  Returns {:ok, mount_ref} | {:error, reason}. Spawns a small keepalive process.
  """
  def mount(spi_host, cs_pin, root, driver \\ ~c"sdspi") do
    case :esp.mount(driver, root, :fat, spi_host: spi_host, cs: cs_pin) do
      {:ok, mref} ->
        _keep = spawn_link(fn -> keep_mount_alive(mref) end)
        {:ok, mref}

      {:error, r} ->
        :io.format(~c"SD mount failed: ~p~n", [r])
        {:error, r}
    end
  end

  defp keep_mount_alive(mref) do
    _ = mref

    receive do
    after
      86_400_000 -> keep_mount_alive(mref)
    end
  end

  # ── Directory / files ─────────────────────────────────────────────────────────

  def print_directory(path) do
    :io.format(~c"Listing ~s~n", [path])

    case :atomvm.posix_opendir(path) do
      {:ok, dir} ->
        print_directory_entries(dir)
        :atomvm.posix_closedir(dir)
        :ok

      {:error, r} ->
        :io.format(~c"opendir(~s) failed: ~p~n", [path, r])
        {:error, r}
    end
  end

  # Sorted full paths ending with .RGB (RAW 3-byte/pixel expected)
  def list_rgb_files(base) do
    names = list_entry_names(base)
    matches = :lists.filter(&Util.has_rgb_extension?/1, names)
    paths = :lists.map(&Util.path_join(base, &1), matches)
    :lists.sort(paths)
  end

  # Open → read `chunk_bytes` → consumer_fun.(bin) per chunk → close
  # Returns {:ok, total_bytes} or {:error, reason}.
  def stream_file_chunks(path, chunk_bytes, consumer_fun) when is_function(consumer_fun, 1) do
    case :atomvm.posix_open(path, [:o_rdonly]) do
      {:ok, fd} ->
        result = stream_loop(fd, chunk_bytes, 0, consumer_fun)
        :atomvm.posix_close(fd)
        result

      {:error, r} ->
        :io.format(~c"open failed: ~p~n", [r])
        {:error, r}
    end
  end

  @doc """
  Return {:ok, byte_count} for `path` by reading in chunks of `chunk_bytes`.
  """
  def file_size(path, chunk_bytes) when is_integer(chunk_bytes) and chunk_bytes > 0 do
    case :atomvm.posix_open(path, [:o_rdonly]) do
      {:ok, fd} ->
        size = file_size_loop(fd, chunk_bytes, 0)
        :atomvm.posix_close(fd)
        {:ok, size}

      {:error, r} ->
        :io.format(~c"open failed: ~p~n", [r])
        {:error, r}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp print_directory_entries(dir) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name_any}} ->
        name = Util.to_charlist_if_needed(name_any)
        if name != [], do: :io.format(~c"  - ~s~n", [name])
        print_directory_entries(dir)

      :eof ->
        :ok

      {:error, r} ->
        :io.format(~c"readdir error: ~p~n", [r])

      _ ->
        :ok
    end
  end

  defp list_entry_names(base) do
    case :atomvm.posix_opendir(base) do
      {:ok, dir} ->
        names = collect_entry_names(dir, [])
        :atomvm.posix_closedir(dir)
        names

      _ ->
        []
    end
  end

  defp collect_entry_names(dir, acc) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name_any}} ->
        name = Util.to_charlist_if_needed(name_any)
        acc2 = if name != [], do: [name | acc], else: acc
        collect_entry_names(dir, acc2)

      :eof ->
        :lists.reverse(acc)

      _ ->
        :lists.reverse(acc)
    end
  end

  defp stream_loop(fd, chunk_bytes, acc, fun) do
    case :atomvm.posix_read(fd, chunk_bytes) do
      {:ok, bin} when is_binary(bin) and bin != <<>> ->
        _ = fun.(bin)
        stream_loop(fd, chunk_bytes, acc + byte_size(bin), fun)

      :eof ->
        {:ok, acc}

      {:error, r} ->
        :io.format(~c"read error: ~p~n", [r])
        {:error, r}

      _ ->
        {:ok, acc}
    end
  end

  defp file_size_loop(fd, chunk_bytes, acc) do
    case :atomvm.posix_read(fd, chunk_bytes) do
      {:ok, bin} when is_binary(bin) and bin != <<>> ->
        file_size_loop(fd, chunk_bytes, acc + byte_size(bin))

      :eof ->
        acc

      {:error, _} ->
        acc

      _ ->
        acc
    end
  end
end
