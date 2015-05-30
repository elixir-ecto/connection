TCPConnection
=============

To try this example:
```
iex -S mix
```

Then once in the shell start the connection:
```elixir
{:ok, conn} = TCPConnection.start_link({127,0,0,1}, 8000, [mode: :binary], 1000)
{:error, closed} = TCPConnection.send(conn, "hello")
{:error, closed} = TCPConnection.recv(conn, 0, 1000)
```
Start a listening socket and accept a connection:
```elixir
{:ok, listener} = :gen_tcp.listen(8000, [active: false, mode: :binary])
{:ok, socket} = :gen_tcp.accept(listener)
:ok = :gen_tcp.send(socket, "hello")
{:ok, "hello"} = TCPConnection.recv(conn, 5, 1000)
:ok = TCPConnection.send(conn, "hi")
{:ok, "hi"} = :gen_tcp.recv(socket, 2, 1000)
:ok = TCPConnection.close(conn)
{:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
```
The TCPConnection process will automatically reconnect (retries every
second):
```elixir
{:ok, socket} = :gen_tcp.accept(listener)
:ok = TCPConnection.send(conn, "back!")
{:ok, "back!"} = :gen_tcp.recv(socket, 5, 1000)
```

