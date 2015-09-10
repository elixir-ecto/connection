{:ok, _} = Application.ensure_all_started(:logger)
ExUnit.start()

defmodule EvalConn do
  use Connection
  def init(fun) when is_function(fun, 0), do: fun.()
  def init(state), do: {:ok, state}

  def handle_call(:state, _, state), do: {:reply, state, state}
  def handle_call(fun, from, state), do: fun.(from, state)

  def handle_cast(fun, state), do: fun.(state)

  def handle_info(:timeout, fun), do: fun.()
  def handle_info(fun, state), do: fun.(state)

  def connect(:backoff, fun), do: fun.()
  def connect(fun, state), do: fun.(state)

  def disconnect(fun, state), do: fun.(state)

  def terminate({:shutdown, fun}, state), do: fun.(state)
  def terminate({:abnormal, fun}, state), do: fun.(state)
  def terminate({{:nocatch, {:abnormal, fun}}, _}, state), do: fun.(state)
  def terminate({{:abnormal, fun}, _}, state), do: fun.(state)
end
