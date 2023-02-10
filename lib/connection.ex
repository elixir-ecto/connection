defmodule Connection do
  @moduledoc ~S"""
  A behaviour module for implementing connection processes.

  The `Connection` behaviour is a superset of the `GenServer` behaviour. The
  additional return values and callbacks are designed to aid building a
  connection process that can handle a peer being (temporarily) unavailable.

  An example `Connection` process:

      defmodule TCPConnection do
        use Connection

        def start_link(host, port, opts, timeout \\ 5000) do
          Connection.start_link(__MODULE__, {host, port, opts, timeout})
        end

        def send(conn, data) do
          Connection.call(conn, {:send, data})
        end

        def recv(conn, bytes, timeout \\ 3000) do
          Connection.call(conn, {:recv, bytes, timeout})
        end

        def close(conn), do: Connection.call(conn, :close)

        def init({host, port, opts, timeout}) do
          s = %{host: host, port: port, opts: opts, timeout: timeout, sock: nil}
          {:connect, :init, s}
        end

        def connect(_, %{sock: nil, host: host, port: port, opts: opts, timeout: timeout} = s) do
          case :gen_tcp.connect(host, port, [active: false] ++ opts, timeout) do
            {:ok, sock} ->
              {:ok, %{s | sock: sock}}

            {:error, _} ->
              {:backoff, 1000, s}
          end
        end

        def disconnect(info, %{sock: sock} = s) do
          :ok = :gen_tcp.close(sock)

          case info do
            {:close, from} ->
              Connection.reply(from, :ok)

            {:error, :closed} ->
              :error_logger.format("Connection closed~n", [])

            {:error, reason} ->
              reason = :inet.format_error(reason)
              :error_logger.format("Connection error: ~s~n", [reason])
          end

          {:connect, :reconnect, %{s | sock: nil}}
        end

        def handle_call(_, _, %{sock: nil} = s) do
          {:reply, {:error, :closed}, s}
        end

        def handle_call({:send, data}, _, %{sock: sock} = s) do
          case :gen_tcp.send(sock, data) do
            :ok ->
              {:reply, :ok, s}

            {:error, _} = error ->
              {:disconnect, error, error, s}
          end
        end

        def handle_call({:recv, bytes, timeout}, _, %{sock: sock} = s) do
          case :gen_tcp.recv(sock, bytes, timeout) do
            {:ok, _} = ok ->
              {:reply, ok, s}

            {:error, :timeout} = timeout ->
              {:reply, timeout, s}

            {:error, _} = error ->
              {:disconnect, error, error, s}
          end
        end

        def handle_call(:close, from, s) do
          {:disconnect, {:close, from}, s}
        end
      end

  The example above follows a common pattern. Try to connect immediately, if
  that fails backoff and retry after a delay. If a retry fails make another
  attempt after another delay. If the process disconnects a reconnection attempt
  is made immediately, if that fails backoff begins.

  Importantly when backing off requests will still be received by the process,
  which will need to be handled. In the above example the process replies with
  `{:error, :closed}` when it is disconnected.
  """

  @behaviour :gen_statem

  @doc """
  Called when the connection process is first started. `start_link/3` will block
  until it returns.

  Returning `{:ok, state}` will cause `start_link/3` to return
  `{:ok, pid}` and the process to enter its loop with state `state` without
  calling `connect/2`.

  This return value is useful when the process connects inside `init/1` so that
  `start_link/3` blocks until a connection is established.

  Returning `{:ok, state, timeout}` is similar to `{:ok, state}`
  except `handle_info(:timeout, state)` will be called after `timeout` if no
  message arrives.

  Returning `{:ok, state, :hibernate}` is similar to
  `{:ok, state}` except the process is hibernated awaiting a message.

  Returning `{:connect, info, state}` will cause `start_link/3` to return
  `{:ok, pid}` and `connect(info, state)` will be called immediately - even if
  messages are in the processes message queue. `state` contains the state of the
  process and `info` should contain any information not contained in the state
  that is needed to connect.

  This return value is very useful because connecting in `connect/2` will not
  block the parent process and a connection attempt is guaranteed to occur
  before any messages are handled, which is not possible when using a
  `GenServer`.

  Returning `{:backoff, timeout, state}` will cause `start_link/3` to return
  `{:ok, pid}` and the process to enter its normal loop with state `state`.
  `connect(:backoff, state)` is called after `timeout` if `connect/2` or
  `disconnect/2` is not called within the timeout.

  This return value can be used to delay or stagger the initial connection
  attempt.

  Returning `{:backoff, timeout, state, timeout2}` is similar to
  `{:backoff, timeout, state}` except `handle_info(:timeout, state)` will be
  called after `timeout2` if no message arrives.

  Returning `{:backoff, timeout, state, :hibernate}` is similar to
  `{:backoff, timeout, state}` except the process hibernates.

  Returning `:ignore` will cause `start_link/3` to return `:ignore` and the
  process will exit normally without entering the loop or calling
  `terminate/2`.

  Returning `{:stop, reason}` will cause `start_link/3` to return
  `{:error, reason}` and the process to exit with reason `reason` without
  entering the loop or calling `terminate/2`.
  """
  @callback init(any) ::
              {:ok, any}
              | {:ok, any, timeout | :hibernate}
              | {:connect, any, any}
              | {:backoff, timeout, any}
              | {:backoff, timeout, any, timeout | :hibernate}
              | :ignore
              | {:stop, any}

  @doc """
  Called when the process should try to connect. The first argument will either
  be the `info` term from `{:connect, info, state}` or
  `{:connect, info, reply, state}`, or `:backoff` if the connection attempt is
  triggered by backing off.

  It might be beneficial to do handshaking in this callback if connecting is
  successful.

  Returning `{:ok, state}` or `{:ok, state, timeout | :hibernate}` will cause
  the process to continue its loop. This should be returned when the connection
  attempt was successful. In the later case `handle_info(:timeout, state)` is
  called after `timeout` if no message has been received, if the third element
  is a timeout. Otherwise if the third element is `:hibernate` the process
  hibernates.

  Returning `{:backoff, timeout, state}` will cause the process to continue
  its loop but `connect(:backoff, state)` will be called after `timeout` if
  `connect/2` or `disconnect/2` is not called before that point.

  This return value is used when a connection attempt fails but another attempt
  should be made after a delay. It might be beneficial to increase the delay
  up to a maximum if successive attempts fail to prevent unnecessary work. If
  several connection processes are connecting to the same peer it may also be
  beneficial to add some jitter (randomness) to the delays. This spreads out the
  connection attempts and helps prevent many attempts occurring at the same time.

  Returning `{:backoff, timeout, state, timeout2 | :hibernate}` is similar to
  `{:backoff, timeout, state}` except `handle_info(:timeout, state)` is called
  after `timeout2` if no message has been received, or if `:hibernate`, the
  process hibernates.

  Returning `{:stop, reason, state}` will terminate the loop and call
  `terminate(reason, state)` before the process exits with reason `reason`.
  """
  @callback connect(any, any) ::
              {:ok, any}
              | {:ok, any, timeout | :hibernate}
              | {:backoff, timeout, any}
              | {:backoff, timeout, any, timeout | :hibernate}
              | {:stop, any, any}

  @doc """
  Called when the process should disconnect. The first argument will either
  be the `info` term from `{:disconnect, info, state}` or
  `{:disconnect, info, reply, state}`. This callback should do any cleaning up
  required to disconnect the connection and update the state of the process.

  Returning `{:connect, info, state}` will call `connect(info, state)`
  immediately - even if there are messages in the message queue.

  Returning `{:backoff, timeout, state}` or
  `{:backoff, timeout, state, timeout2 | :hibernate}` starts a backoff timer and
  behaves the same as when returned from `connect/2`. See the `connect/2`
  callback for more information.

  Returning `{:noconnect, state}` or `{:noconnect, state, timeout | :hibernate}`
  will cause the process to continue is loop (and NOT call `connect/2` to
  try to reconnect). In the later case a timeout is started or the process
  hibernates.

  Returning `{:stop, reason, state}` will terminate the loop and call
  `terminate(reason, state)` before the process exits with reason `reason`.
  """
  @callback disconnect(any, any) ::
              {:connect, any, any}
              | {:backoff, timeout, any}
              | {:backoff, timeout, any, timeout | :hibernate}
              | {:noconnect, any}
              | {:noconnect, any, timeout | :hibernate}
              | {:stop, any, any}

  @doc """
  Called when the process receives a call message sent by `call/3`. This
  callback has the same arguments as the `GenServer` equivalent and the
  `:reply`, `:noreply` and `:stop` return tuples behave the same. However
  there are a few additional return values:

  Returning `{:connect, info, reply, state}` will reply to the call with `reply`
  and immediately call `connect(info, state)`. Similarly for
  `{:disconnect, info, reply, state}`, except `disconnect/2` is called.

  Returning `{:connect, info, state}` or `{:disconnect, info, state}` will
  call the relevant callback immediately without replying to the call. This
  might be useful when the call should block until the process has connected,
  failed to connect or disconnected. The second argument passed to this callback
  can be included in the `info` or `state` terms and a reply sent in the next
  or a later callback using `reply/2`.
  """
  @callback handle_call(any, {pid, any}, any) ::
              {:reply, any, any}
              | {:reply, any, any, timeout | :hibernate}
              | {:noreply, any}
              | {:noreply, any, timeout | :hibernate}
              | {:disconnect | :connect, any, any, any}
              | {:disconnect | :connect, any, any}
              | {:stop, any, any}
              | {:stop, any, any, any}

  @doc """
  Called when the process receives a cast message sent by `cast/3`. This
  callback has the same arguments as the `GenServer` equivalent and the
  `:noreply` and `:stop` return tuples behave the same. However
  there are two additional return values:

  Returning `{:connect, info, state}` will immediately call
  `connect(info, state)`. Similarly for `{:disconnect, info, state}`,
  except `disconnect/2` is called.
  """
  @callback handle_cast(any, any) ::
              {:noreply, any}
              | {:noreply, any, timeout | :hibernate}
              | {:disconnect | :connect, any, any}
              | {:stop, any, any}

  @doc """
  Called when the process receives a message that is not a call or cast. This
  callback has the same arguments as the `GenServer` equivalent and the `:noreply`
  and `:stop` return tuples behave the same. However there are two additional
  return values:

  Returning `{:connect, info, state}` will immediately call
  `connect(info, state)`. Similarly for `{:disconnect, info, state}`,
  except `disconnect/2` is called.
  """
  @callback handle_info(any, any) ::
              {:noreply, any}
              | {:noreply, any, timeout | :hibernate}
              | {:disconnect | :connect, any, any}
              | {:stop, any, any}

  @doc """
  This callback is the same as the `GenServer` equivalent and is used to change
  the state when loading a different version of the callback module.
  """
  @callback code_change(any, any, any) :: {:ok, any}

  @doc """
  This callback is the same as the `GenServer` equivalent and is called when the
  process terminates. The first argument is the reason the process is about
  to exit with.
  """
  @callback terminate(any, any) :: any

  defmacro __using__(_) do
    quote location: :keep do
      @behaviour Connection

      # The default implementations of init/1, handle_call/3, handle_info/2,
      # handle_cast/2, terminate/2 and code_change/3 have been taken verbatim
      # from Elixir's GenServer default implementation.

      @doc false
      def init(args) do
        {:ok, args}
      end

      @doc false
      def handle_call(msg, _from, state) do
        # We do this to trick dialyzer to not complain about non-local returns.
        reason = {:bad_call, msg}

        case :erlang.phash2(1, 1) do
          0 -> exit(reason)
          1 -> {:stop, reason, state}
        end
      end

      @doc false
      def handle_info(_msg, state) do
        {:noreply, state}
      end

      @doc false
      def handle_cast(msg, state) do
        # We do this to trick dialyzer to not complain about non-local returns.
        reason = {:bad_cast, msg}

        case :erlang.phash2(1, 1) do
          0 -> exit(reason)
          1 -> {:stop, reason, state}
        end
      end

      @doc false
      def terminate(_reason, _state) do
        :ok
      end

      @doc false
      def code_change(_old, state, _extra) do
        {:ok, state}
      end

      @doc false
      def connect(info, state) do
        reason = {:bad_connect, info}

        case :erlang.phash2(1, 1) do
          0 -> exit(reason)
          1 -> {:stop, reason, state}
        end
      end

      @doc false
      def disconnect(info, state) do
        reason = {:bad_disconnect, info}

        case :erlang.phash2(1, 1) do
          0 -> exit(reason)
          1 -> {:stop, reason, state}
        end
      end

      defoverridable init: 1,
                     handle_call: 3,
                     handle_info: 2,
                     handle_cast: 2,
                     terminate: 2,
                     code_change: 3,
                     connect: 2,
                     disconnect: 2
    end
  end

  @doc """
  Starts a `Connection` process linked to the current process.

  This function is used to start a `Connection` process in a supervision tree.
  The process will be started by calling `init/1` in the callback module with
  the given argument.

  This function will return after `init/1` has returned in the spawned process.
  The return values are controlled by the `init/1` callback.

  See `GenServer.start_link/3` for more information.
  """
  @spec start_link(module, any, GenServer.options()) :: GenServer.on_start()
  def start_link(mod, args, opts \\ []) do
    start(mod, args, opts, :link)
  end

  @doc """
  Starts a `Connection` process without links (outside of a supervision tree).

  See `start_link/3` for more information.
  """
  @spec start(module, any, GenServer.options()) :: GenServer.on_start()
  def start(mod, args, opts \\ []) do
    start(mod, args, opts, :nolink)
  end

  @doc """
  Sends a synchronous call to the `Connection` process and waits for a reply.

  See `GenServer.call/2` for more information.
  """
  defdelegate call(conn, req), to: :gen_statem

  @doc """
  Sends a synchronous request to the `Connection` process and waits for a reply.

  See `GenServer.call/3` for more information.
  """
  defdelegate call(conn, req, timeout), to: :gen_statem

  @doc """
  Sends a asynchronous request to the `Connection` process.

  See `GenServer.cast/2` for more information.
  """
  defdelegate cast(conn, req), to: :gen_statem

  @doc """
  Sends a reply to a request sent by `call/3`.

  See `GenServer.reply/2` for more information.
  """
  defdelegate reply(from, response), to: :gen_statem

  # We need a state for the gen_statem, but we only need one. We're using gen_statem for
  # other features, such as timeouts, but we don't need the state.
  @state :no_state

  @cancel_backoff_action {{:timeout, :backoff}, :infinity, :no_content}

  defstruct [:mod, :backoff, :raise, :mod_state]

  ## :gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init({mod, args}) do
    try do
      apply(mod, :init, [args])
    catch
      :exit, reason ->
        exit(reason)

      :error, reason ->
        exit({reason, __STACKTRACE__})

      :throw, value ->
        exit({{:nocatch, value}, __STACKTRACE__})
    else
      {:ok, mod_state} ->
        {:ok, @state, %__MODULE__{mod: mod, mod_state: mod_state}}

      {:ok, mod_state, timeout} ->
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, callback_timeout_action(timeout)}

      {:connect, info, mod_state} ->
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, {:next_event, :internal, {:connect, info}}}

      {:backoff, backoff_timeout, mod_state} ->
        backoff_action = {{:timeout, :backoff}, backoff_timeout, :no_content}
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, backoff_action}

      {:backoff, backoff_timeout, mod_state, timeout} ->
        backoff_action = {{:timeout, :backoff}, backoff_timeout, :no_content}
        timeout_action = callback_timeout_action(timeout)
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, [backoff_action, timeout_action]}

      :ignore ->
        :ignore

      {:stop, reason} ->
        {:stop, reason}

      other ->
        exit({:bad_return_value, other})
    end
  end

  @impl :gen_statem
  def handle_event({:call, from}, request, @state, %__MODULE__{} = s) do
    %{mod: mod, mod_state: mod_state} = s

    try do
      apply(mod, :handle_call, [request, from, mod_state])
    catch
      :throw, value ->
        :erlang.raise(:error, {:nocatch, value}, __STACKTRACE__)
    else
      {:noreply, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}}

      {:noreply, mod_state, timeout} ->
        {:keep_state, %{s | mod_state: mod_state}, callback_timeout_action(timeout)}

      {:reply, reply, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}, {:reply, from, reply}}

      {:reply, reply, mod_state, timeout} ->
        actions = [{:reply, from, reply}, callback_timeout_action(timeout)]
        {:keep_state, %{s | mod_state: mod_state}, actions}

      {:connect, info, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}, {:next_event, :internal, {:connect, info}}}

      {:connect, info, reply, mod_state} ->
        actions = [{:reply, from, reply}, {:next_event, :internal, {:connect, info}}]
        {:keep_state, %{s | mod_state: mod_state}, actions}

      {:disconnect, info, mod_state} ->
        # TODO: see disconnect/3 private function for how to handle this event
        {:keep_state, %{s | mod_state: mod_state}, {:next_event, :internal, {:disconnect, info}}}

      {:disconnect, info, reply, mod_state} ->
        actions = [{:reply, from, reply}, {:next_event, :internal, {:disconnect, info}}]
        {:keep_state, %{s | mod_state: mod_state}, actions}

      {:stop, reason, mod_state} ->
        {:stop, reason, %{s | mod_state: mod_state}}

      {:stop, reason, reply, mod_state} ->
        {:stop_and_reply, reason, {:reply, from, reply}, %{s | mod_state: mod_state}}

      other ->
        {:stop, {:bad_return_value, other}, %{s | mod_state: mod_state}}
    end
  end

  def handle_event(:cast, request, @state, %__MODULE__{} = s) do
    handle_async(:handle_cast, request, s)
  end

  def handle_event(:info, msg, @state, %__MODULE__{} = s) do
    handle_async(:handle_info, msg, s)
  end

  def handle_event(:timeout, :no_content, @state, %__MODULE__{} = s) do
    handle_async(:handle_info, :timeout, s)
  end

  def handle_event({:timeout, :backoff}, :no_content, @state, %__MODULE__{} = s) do
    {:keep_state, s, {:next_event, :internal, {:connect, :backoff}}}
  end

  def handle_event(:internal, {:connect, info}, @state, %__MODULE__{} = s) do
    %{mod: mod, mod_state: mod_state} = s

    try do
      apply(mod, :connect, [info, mod_state])
    catch
      class, reason ->
        stack = __STACKTRACE__
        callback_stop(class, reason, stack, %{s | mod_state: mod_state})
    else
      {:ok, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}, @cancel_backoff_action}

      {:ok, mod_state, timeout} ->
        actions = [@cancel_backoff_action, callback_timeout_action(timeout)]
        {:keep_state, %{s | mod_state: mod_state}, actions}

      {:backoff, backoff_timeout, mod_state} ->
        backoff_action = {{:timeout, :backoff}, backoff_timeout, :no_content}
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, backoff_action}

      {:backoff, backoff_timeout, mod_state, timeout} ->
        backoff_action = {{:timeout, :backoff}, backoff_timeout, :no_content}
        timeout_action = callback_timeout_action(timeout)
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, [backoff_action, timeout_action]}

      {:stop, reason, mod_state} ->
        {:stop, reason, %{s | mod_state: mod_state}}

      other ->
        {:stop, {:bad_return_value, other}, %{s | mod_state: mod_state}}
    end
  end

  def handle_event(:internal, {:disconnect, info}, @state, %__MODULE__{} = s) do
    %{mod: mod, mod_state: mod_state} = s

    try do
      apply(mod, :disconnect, [info, mod_state])
    catch
      class, reason ->
        stack = __STACKTRACE__
        callback_stop(class, reason, stack, %{s | mod_state: mod_state})
    else
      {:connect, info, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}, {:next_event, :internal, {:connect, info}}}

      {:noconnect, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}, @cancel_backoff_action}

      {:noconnect, mod_state, timeout} ->
        actions = [@cancel_backoff_action, callback_timeout_action(timeout)]
        {:keep_state, %{s | mod_state: mod_state}, actions}

      {:backoff, backoff_timeout, mod_state} ->
        backoff_action = {{:timeout, :backoff}, backoff_timeout, :no_content}
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, backoff_action}

      {:backoff, backoff_timeout, mod_state, timeout} ->
        backoff_action = {{:timeout, :backoff}, backoff_timeout, :no_content}
        timeout_action = callback_timeout_action(timeout)
        data = %__MODULE__{mod: mod, mod_state: mod_state}
        {:ok, @state, data, [backoff_action, timeout_action]}

      {:stop, reason, mod_state} ->
        {:stop, reason, %{s | mod_state: mod_state}}

      other ->
        {:stop, {:bad_return_value, other}, %{s | mod_state: mod_state}}
    end
  end

  @doc false
  @impl :gen_statem
  def code_change(old_vsn, @state, %{mod: mod, mod_state: mod_state} = s, extra) do
    try do
      apply(mod, :code_change, [old_vsn, mod_state, extra])
    catch
      :throw, value ->
        exit({{:nocatch, value}, __STACKTRACE__})
    else
      {:ok, mod_state} ->
        {:ok, @state, %{s | mod_state: mod_state}}
    end
  end

  @doc false
  @impl :gen_statem
  def format_status(:normal, [pdict, @state, %{mod: mod, mod_state: mod_state}]) do
    try do
      apply(mod, :format_status, [:normal, [pdict, mod_state]])
    catch
      _, _ ->
        [{:data, [{~c"State", mod_state}]}]
    else
      mod_status ->
        mod_status
    end
  end

  def format_status(:terminate, [pdict, @state, %{mod: mod, mod_state: mod_state}]) do
    try do
      apply(mod, :format_status, [:terminate, [pdict, mod_state]])
    catch
      _, _ ->
        mod_state
    else
      mod_state ->
        mod_state
    end
  end

  @doc false
  @impl :gen_statem
  def terminate(reason, state, s)

  def terminate(reason, @state, %__MODULE__{mod: mod, mod_state: mod_state, raise: nil}) do
    apply(mod, :terminate, [reason, mod_state])
  end

  def terminate(stop, @state, %__MODULE__{raise: {class, reason, stack}} = s) do
    %{mod: mod, mod_state: mod_state} = s

    try do
      apply(mod, :terminate, [stop, mod_state])
    catch
      :throw, value ->
        :erlang.raise(:error, {:nocatch, value}, __STACKTRACE__)
    else
      _ when stop in [:normal, :shutdown] ->
        :ok

      _ when tuple_size(stop) == 2 and elem(stop, 0) == :shutdown ->
        :ok

      _ ->
        :erlang.raise(class, reason, stack)
    end
  end

  # start helpers

  defp start(mod, args, options, link) do
    start_fun =
      case link do
        :link -> :start_link
        :nolink -> :start
      end

    args =
      case Keyword.pop(options, :name) do
        {nil, opts} -> [__MODULE__, {mod, args}, opts]
        {atom, opts} when is_atom(atom) -> [{:local, atom}, __MODULE__, {mod, args}, opts]
        {{:global, _} = name, opts} -> [name, __MODULE__, {mod, args}, opts]
        {{:via, _, _} = name, opts} -> [name, __MODULE__, {mod, args}, opts]
      end

    apply(:gen_statem, start_fun, args)
  end

  # init helpers

  ## GenServer helpers

  # In order to have new mod_state in terminate/2 must return the exit reason.
  # However to get the correct GenServer report (exit with stacktrace),
  # include stacktrace in reason and re-raise after calling mod.terminate/2 if
  # it does not raise.

  defp callback_stop(:throw, value, stack, s) do
    callback_stop(:error, {:nocatch, value}, stack, s)
  end

  defp callback_stop(class, reason, stack, s) do
    raise = {class, reason, stack}
    {:stop, stop_reason(class, reason, stack), %{s | raise: raise}}
  end

  defp stop_reason(:error, reason, stack), do: {reason, stack}
  defp stop_reason(:exit, reason, _), do: reason

  defp handle_async(fun, msg, %{mod: mod, mod_state: mod_state} = s) do
    try do
      apply(mod, fun, [msg, mod_state])
    catch
      :throw, value ->
        :erlang.raise(:error, {:nocatch, value}, __STACKTRACE__)
    else
      {:noreply, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}}

      {:noreply, mod_state, timeout} ->
        {:keep_state, %{s | mod_state: mod_state}, callback_timeout_action(timeout)}

      {:connect, info, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}, {:next_event, :internal, {:connect, info}}}

      {:disconnect, info, mod_state} ->
        {:keep_state, %{s | mod_state: mod_state}, {:next_event, :internal, {:disconnect, info}}}

      {:stop, reason, mod_state} ->
        {:stop, reason, %{s | mod_state: mod_state}}

      other ->
        {:stop, {:bad_return_value, other}, %{s | mod_state: mod_state}}
    end
  end

  # The gen_statem action to use when a Connection callback returns {..., timeout}.
  defp callback_timeout_action(:hibernate), do: :hibernate
  defp callback_timeout_action(timeout), do: {:timeout, timeout, :no_content}
end
