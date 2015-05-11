Connection
==========

Prototype of `Connection` behaviour. The API is similar to the GenServer
API. There are 2 additional callbacks `connect/1` and `disconnect/1`:

```elixir
  defcallback init(any) ::
    {:connect, any} |
    {:noconnect, any} | {:noconnect, any, timeout | :hibernate} |
    :ignore | {:stop, any}

  defcallback connect(any) ::
    {:ok, any} | {:ok, any, timeout | :hibernate} |
    {:stop, any, any}

  defcallback disconnect(any) ::
    {:connect, any} |
    {:noconnect, any} | {:noconnect, any, timeout | :hibernate} |
    {:stop, any, any}

  defcallback handle_call(any, {pid, any}, any) ::
    {:reply, any, any} | {:reply, any, any, timeout | :hibernate} |
    {:noreply, any} | {:noreply, any, timeout | :hibernate} |
    {:disconnect | :connect, any} | {:disconnect | :connect, any, any} |
    {:stop, any, any} | {:stop, any, any, any}

  defcallback handle_info(any, any) ::
    {:noreply, any} | {:noreply, any, timeout | :hibernate} |
    {:disconnect | :connect, any} |
    {:stop, any, any}

  defcallback code_change(any, any, any) :: {:ok, any}

  defcallback terminate(any, any) :: any
```

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

  def init({host, port, opts, timeout}) do
    s = %{host: host, port: port, opts: opts, timeout: timeout, sock: nil}
    {:connect, s}
  end

  def connect(%{sock: nil, host: host, port: port, opts: opts,
  timeout: timeout} = s) do
    case :gen_tcp.connect(host, port, [active: false] ++ opts, timeout) do
      {:ok, sock} ->
        {:ok, %{s | sock: sock}}
      {:error, _} ->
        :erlang.send_after(1000, self(), :reconnect)
        {:ok, s}
    end
  end

  def disconnect(%{sock: sock} = s) do
    :ok = :gen_tcp.close(sock)
    {:connect, %{s | sock: nil}}
  end

  def handle_call(_, _, %{sock: nil} = s) do
    {:reply, {:error, :closed}, s}
  end
  def handle_call({:send, data}, _, %{sock: sock} = s) do
    case :gen_tcp.send(sock, data) do
      :ok ->
        {:reply, :ok, s}
      {:error, _} = error ->
        {:reply, error, s}
    end
  end
  def handle_call({:recv, bytes, timeout}, _, %{sock: sock} = s) do
    case :gen_tcp.recv(sock, bytes, timeout) do
      {:ok, _} = ok ->
        {:reply, ok, s}
      {:error, :timeout} = timeout ->
        {:reply, timeout, s}
      {:error, _} = error ->
        {:disconnect, error, s}
    end
  end

  def handle_cast(req, s), do: {:stop, {:bad_cast, req}, s}

  def handle_info(:reconnect, %{sock: nil} = s), do: {:connect, s}
  def handle_info(_, s), do: {:noreply, s}

  def code_change(_, s, _), do: {:ok, s}

  def terminate(_, _), do: :ok
end
```
