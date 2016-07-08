defmodule Aws.Iot.ThingShadow.EventHandler do

  @moduledoc ~S"""
  GenEvent executes handlers sequentially in a single loop of the GenEvent.manager process.
  To avoid this bottleneck, we ensure that handlers do nothing other than forwarding events.
  Also, please use `GenEvent.add_mon_handler/3` if available, so that the calling process that adds the handler would receive the message `{:gen_event_EXIT, handler, reason}` if the event handler is later deleted.

  ## Usage
    iex> {:ok, event_manager} = GenEvent.start_link([])
    iex> GenEvent.add_mon_handler(event_manager, EventHandler, [broadcast: {MyApp.PubSub, "thing_shadow_event"}])

  """

  use GenEvent
  alias Phoenix.PubSub

  @backpressure_timeout 5000

  ## Client API ##

  @doc """
  Provideds an external API to make it easy to do garbage collection on `manager`.

  Only required to be called once for each GenEvent.manager, as the GenEvent.manager will perform garbage-collection for all registered handlers, before processing the next message.
  """
  @spec hibernate(GenEvent.handler, GenEvent.manager) :: :ok
  def hibernate(handler \\ __MODULE__, manager) do
    GenEvent.call(manager, handler, :hibernate)
  end


  @doc """
  Adds `pubsub_topic` to the list of GenServers that would be forwarded any incoming event from `manager` using `Phoenix.PubSub.broadcast/3`

  This function is not necessary (as more of the same GenEvent.handler could be added to a GenEvent.manager), but is provided for completeness.
  """
  @spec add_broadcast(GenEvent.handler, GenEvent.manager, {GenServer.server, binary}) :: :ok
  def add_broadcast(handler \\ __MODULE__, manager, pubsub_topic = {_pubsub_server, _topic}) do
    GenEvent.call(manager, handler, {:add_broadcast, pubsub_topic})
  end

  @doc """
  Removes `pubsub_topic` from the list of GenServers that would be forwarded any incoming event from `manager` using `Phoenix.PubSub.broadcast/3`

  This function is not necessary (as more of the same GenEvent.handler could be added to a GenEvent.manager), but is provided for completeness.
  """
  @spec remove_broadcast(GenEvent.handler, GenEvent.manager, {GenServer.server, binary}) :: :ok
  def remove_broadcast(handler \\ __MODULE__, manager, pubsub_topic = {_pubsub_server, _topic}) do
    GenEvent.call(manager, handler, {:remove_broadcast, pubsub_topic})
  end  

  @doc """
  Adds `server_process` to the list of GenServers that would be forwarded any incoming event from `manager` using `Genserver.cast/2`

  This function is not necessary (as more of the same GenEvent.handler could be added to a GenEvent.manager), but is provided for completeness.
  """
  @spec add_cast(GenEvent.handler, GenEvent.manager, GenServer.server) :: :ok
  def add_cast(handler \\ __MODULE__, manager, server_process) do
    GenEvent.call(manager, handler, {:add_cast, server_process})
  end

  @doc """
  Removes `server_process` from the list of GenServers that would be forwarded any incoming event from `manager` using `Genserver.cast/2`

  This function is not necessary (as more of the same GenEvent.handler could be added to a GenEvent.manager), but is provided for completeness.
  """
  @spec remove_cast(GenEvent.handler, GenEvent.manager, GenServer.server) :: :ok
  def remove_cast(handler \\ __MODULE__, manager, server_process) do
    GenEvent.call(manager, handler, {:remove_cast, server_process})
  end

  @doc """
  Adds `server_process` to the list of GenServers that would be forwarded any incoming event from `manager` using `Genserver.call/2`

  This function is required so there can be a single backpressure timeout.
  Many more of the same GenEvent.handler added to a GenEvent.manager would only increase the overall backpressure timeout.
  """
  @spec add_call(GenEvent.handler, GenEvent.manager, GenServer.server) :: :ok
  def add_call(handler \\ __MODULE__, manager, server_process) do
    GenEvent.call(manager, handler, {:add_call, server_process})
  end

  @doc """
  Removes `server_process` from the list of GenServers that would be forwarded any incoming event from `manager` using `Genserver.call/2`

  This function is required so there can be a single backpressure timeout.
  Many more of the same GenEvent.handler added to a GenEvent.manager would only increase the overall backpressure timeout.
  """
  @spec remove_call(GenEvent.handler, GenEvent.manager, GenServer.server) :: :ok
  def remove_call(handler \\ __MODULE__, manager, server_process) do
    GenEvent.call(manager, handler, {:remove_call, server_process})
  end


  ## GenEvent Handler Callbacks ##

  @doc """
  Initializes the state of the handler during `GenEvent.add_handler/3` (and `GenEvent.add_mon_handler/3`) 

  - `args` should be in the form of [broadcast: pubsub_process1, cast: genserver_process1, cast: genserver_process2].
  Use the form of [call: server_process1] only when backpressure is desired to prevent too many pending async messages in process mailbox.
  """
  def init(args) when is_list(args) do
    init(args, %{broadcast_to: [], cast_to: [], call_to: []})
  end
  def init([{:broadcast, pubsub_topic = {_pubsub_server, _topic}} | args], state = %{broadcast_to: broadcast_to}) do
    if Code.ensure_loaded?(PubSub) do
      init(args, %{state | broadcast_to: [pubsub_topic | broadcast_to] })
    else
      {:error, "Specified broadcast, but Phoenix.PubSub dependency is not loaded"}
    end
  end
  def init([{:cast, server_process} | args], state = %{cast_to: cast_to}) do
    init(args, %{state | cast_to: [server_process | cast_to] })
  end
  def init([{:call, server_process} | args], state = %{call_to: call_to}) do
    init(args, %{state | call_to: [server_process | call_to] })
  end
  def init([ _unknown | args], state) do
    # Skip unknown arg
    init(args, state)
  end
  def init([], state) do
    # End of args
    {:ok, state}
  end

  def handle_event(event, state = %{broadcast_to: broadcast_to, cast_to: cast_to, call_to: call_to}) do
    # Forward event to all PubSub topics in broadcast_to in a concurrent manner
    broadcast_to
    |> Enum.reverse
    |> Enum.each(fn {server_process, topic} -> PubSub.broadcast(server_process, topic, event) end)

    # Forward event to all GenServers in cast_to in a concurrent manner
    cast_to 
    |> Enum.reverse 
    |> Enum.each(fn server_process -> GenServer.cast(server_process, event) end)

    # Forward event to all GenServers in call_to in a concurrent manner
    call_to 
    |> Enum.reverse 
    |> Enum.map(fn server_process -> Task.async(GenServer, :call, [server_process, event]) end) 
    |> Task.yield_many(@backpressure_timeout)
    |> Enum.map(fn {task, res} ->
          # Shutdown the tasks that did not reply nor exit
          res || Task.shutdown(task, :brutal_kill)
        end)

    {:ok, state}
  end

  def handle_call(:hibernate, state) do
    {:ok, :ok, state, :hibernate}
  end

  def handle_call({:add_broadcast, pubsub_topic = {_pubsub_server, _topic}}, state = %{broadcast_to: broadcast_to}) do
    if Code.ensure_loaded?(PubSub) do
      if Enum.any?(broadcast_to, &(&1 == pubsub_topic) ) do
        {:ok, :ok, state}
      else
        {:ok, :ok, %{state | broadcast_to: [pubsub_topic | broadcast_to] } }
      end

    else
      {:error, "Specified broadcast, but Phoenix.PubSub dependency is not loaded"}
    end
  end

  def handle_call({:remove_broadcast, pubsub_topic = {_pubsub_server, _topic}}, state = %{broadcast_to: broadcast_to}) do
    broadcast_to = broadcast_to |> Enum.filter(&(&1 != pubsub_topic))
    {:ok, :ok, %{state | broadcast_to: broadcast_to } }
  end

  def handle_call({:add_cast, server_process}, state = %{cast_to: cast_to}) do
    if Enum.any?(cast_to, &(&1 == server_process) ) do
      {:ok, :ok, state}
    else
      {:ok, :ok, %{state | cast_to: [server_process | cast_to] } }
    end
  end

  def handle_call({:remove_cast, server_process}, state = %{cast_to: cast_to}) do
    cast_to = cast_to |> Enum.filter(&(&1 != server_process))
    {:ok, :ok, %{state | cast_to: cast_to } }
  end

  def handle_call({:add_call, server_process}, state = %{call_to: call_to}) do
    if Enum.any?(call_to, &(&1 == server_process) ) do
      {:ok, :ok, state}
    else
      {:ok, :ok, %{state | call_to: [server_process | call_to] } }
    end
  end

  def handle_call({:remove_call, server_process}, state = %{call_to: call_to}) do
    call_to = call_to |> Enum.filter(&(&1 != server_process))
    {:ok, :ok, %{state | call_to: call_to } }
  end

end