defmodule SampleApp do
  @pin 21

  def start() do
    :gpio.set_pin_mode(@pin, :output)
    loop(@pin, :low)
  end

  defp loop(pin, level) do
    :io.format(~c"Setting pin ~p ~p~n", [pin, level])
    :gpio.digital_write(pin, level)
    Process.sleep(1000)
    loop(pin, toggle(level))
  end

  defp toggle(:high), do: :low
  defp toggle(:low), do: :high
end
