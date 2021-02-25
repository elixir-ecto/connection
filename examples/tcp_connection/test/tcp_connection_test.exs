defmodule TCPConnectionTest do
  use ExUnit.Case

  test "the truth" do
    {:ok, listener} = :gen_tcp.listen(0, active: false, mode: :binary)
    {:ok, port} = :inet.port(listener)
    conn = start_supervised!({TCPConnection, host: {127, 0, 0, 1}, port: port, mode: :binary})
    {:ok, socket} = :gen_tcp.accept(listener, 1000)

    assert :gen_tcp.send(socket, "hello") == :ok
    assert TCPConnection.recv(conn, 5, 1000) == {:ok, "hello"}
    assert TCPConnection.send(conn, "hi") == :ok
    assert :gen_tcp.recv(socket, 2, 1000) == {:ok, "hi"}
    assert TCPConnection.close(conn) == :ok
    assert :gen_tcp.recv(socket, 0, 1000) == {:error, :closed}

    {:ok, socket} = :gen_tcp.accept(listener, 1000)

    assert TCPConnection.send(conn, "back!") == :ok
    assert :gen_tcp.recv(socket, 5, 1000) == {:ok, "back!"}
  end
end
