Connection
==========

Prototype of `Connection` behaviour. The API is a superset of the
GenServer API. There are 3 additional callbacks `handle_connect/1`,
`handle_handshake/1` and `handle_disconnect/1`. One of the these
callbacks is called when `:connect`, `:handshake` or `:disconnect`
is used in the place of a timeout or `:hibernate` in a return value.

```elixir
defmodule Example do

  @behaviour Connection

  def start_link(host, port, opts, timeout \\ 5000) do
    Connection.start_link(__MODULE__, {host, port, opts, timeout})
  end

  def send(conn, data), do: Connection.call(conn, {:send, data})

  def recv(conn, bytes, timeout \\ 3000) do
    Connection.call(conn, {:recv, bytes, timeout})
  end

  def disconnect(conn), do: Connection.cast(conn, :disconnect)

  def init({host, port, opts, timeout}) do
    s = %{host: host, port: port, opts: opts, timeout: timeout, sock: nil}
    {:ok, s, :connect}
  end

  def handle_connect(%{sock: nil, host: host, port: port, opts: opts,
  timeout: timeout} = s) do
    case :gen_tcp.connect(host, port, [active: false] ++ opts, timeout) do
      {:ok, sock} ->
        {:ok, %{s | sock: sock}, :handshake}
      {:error, _} ->
        :erlang.send_after(1000, self(), :reconnect)
        {:ok, s}
    end
  end

  def handle_handshake(s), do: {:ok, s}

  def handle_disconnect(%{sock: sock} = s) do
    :ok = :gen_tcp.close(sock)
    {:ok, %{s | sock: nil}, :connect}
  end

  def handle_call(_, _, %{sock: nil} = s) do
    {:reply, {:error, :closed}, s}
  end
  def handle_call({:send, data}, _, %{sock: sock} = s) do
    case :gen_tcp.send(sock, data) do
      :ok ->
        {:reply, :ok, s}
      {:error, _} = error ->
        {:reply, error, s, :disconnect}
    end
  end
  def handle_call({:recv, bytes, timeout}, _, %{sock: sock} = s) do
    case :gen_tcp.recv(sock, bytes, timeout) do
      {:ok, _} = ok ->
        {:reply, ok, s}
      {:error, :timeout} = timeout ->
        {:reply, timeout, s}
      {:error, _} = error ->
        {:reply, error, s, :disconnect}
    end
  end

  def handle_cast(:disconnect, %{sock: nil} = s), do: {:noreply, s}
  def handle_cast(:disconnect, s), do: {:noreply, s, :disconnect}

  def handle_info(:reconnect, %{sock: nil} = s), do: {:noreply, s, :connect}
  def handle_info(_, s), do: {:noreply, s}

  def code_change(_, s, _), do: {:ok, s}

  def terminate(_, _), do: :ok
end
```
