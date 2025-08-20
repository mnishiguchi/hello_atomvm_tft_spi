defmodule SampleApp.Util do
  @moduledoc """
  Small AtomVM-friendly helpers. Paths and filenames are **charlists**.
  """

  # Avoid Kernel.to_charlist/1 clash
  @doc "Return a charlist: pass lists through; convert binaries."
  def to_charlist_if_needed(x) when is_list(x), do: x
  def to_charlist_if_needed(x) when is_binary(x), do: :erlang.binary_to_list(x)
  def to_charlist_if_needed(x), do: x

  @doc "True if name ends with .RGB / .rgb (RAW 3-byte/pixel expected)."
  def has_rgb_extension?(name_cs) do
    case :lists.reverse(name_cs) do
      [?B, ?G, ?R, ?. | _] -> true
      [?b, ?g, ?r, ?. | _] -> true
      _ -> false
    end
  end

  @doc "Join two charlist paths without duplicate slash."
  def path_join(base, rel_any) do
    rel = to_charlist_if_needed(rel_any)
    sep = if base != [] and last_char(base) == ?/, do: [], else: [?/]

    rr =
      case rel do
        [?/ | rest] -> rest
        _ -> rel
      end

    base ++ sep ++ rr
  end

  @doc "Return the last character of a non-empty charlist."
  def last_char([h]), do: h
  def last_char([_ | t]), do: last_char(t)
end
