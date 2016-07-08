defmodule Aws.Iot.ThingShadow.Client do

  @moduledoc ~S"""
  Implements the AWS IoT ThingShadow Data Flow behaviour.
  Uses the `:emqttc` erlang module for the underlyting MQTT connection.

  Closely follows the logic from the official nodejs library, with minor deviations to adapt to Elixir Coding Conventions:
  https://github.com/aws/aws-iot-device-sdk-js/blob/master/thing/index.js


  ## Events

  ### Event :message

  `{:message, topic, message}`

  Emitted when a message is received on a topic not related to any Thing Shadows:

  * `topic` topic of the received packet
  * `message` payload of the received packet

  ### Event :status

  `{:status, thing_name, stat, client_token, state_object}`

  Emitted when an operation update|get|delete completes.

  * `thing_name` Emitted when an operation update|get|delete completes.
  * `stat` status of the operation :accepted|:rejected
  * `client_token` the operation's clientToken
  * `state_object` the stateObject returned for the operation

  ### Event :delta

  `{:delta, thing_name, state_object}`

  Emitted when a delta has been received for a registered Thing Shadow.

  * `thing_name` name of the Thing Shadow for which the operation has completed
  * `state_object` the stateObject returned for the operation

  ### Event :foreign_state_change

  `{:foreign_state_change, thing_name, operation, state_object}`

  * `thing_name` name of the Thing Shadow for which the operation has completed
  * `operation` operation performed by the foreign client :update|:delete
  * `state_object` the stateObject returned for the operation

  This event allows an application to be aware of successful update or delete operations performed by different clients.

  ### Event :timeout

  `{:timeout, thing_name, client_token}`

  Emitted when an operation update|get|delete has timed out.

  * `thing_name` name of the Thing Shadow that has received a timeout
  * `client_token` the operation's clientToken

  Applications can use clientToken values to correlate timeout events with the operations that they are associated with by saving the clientTokens returned from each operation.


  ## Note

  Elixir/Erlang's GenEvent executes handlers sequentially in a single loop of the GenEvent.manager process.
  To avoid this bottleneck, please ensure that each ThingShadow process has a different `GenEvent.manager`.
  Also, please use `ThingShadow.EventHandler` module together with `GenEvent.add_mon_handler/3` if available.
  """

  use GenServer

  ## Client API ##

  @doc """
  Starts a `ThingShadow.Client` process linked to the current process.
  There are 2 ways to start the process.

  ## Method 1
  - `event_manager` should be a `GenEvent.manager` type, procuded by calling `GenEvent.start_link/1`
  - `mqttc_options` should be in the Keyword format that is expected by `:emqttc.start_link/1`

  ## Method 2
  - `event_manager` should be a `GenEvent.manager` type, produced by calling `GenEvent.start_link/1`
  - `app_name` should be the Mix/OTP application name (atom) that has been configured in config/config.exs file

  The configuration should look like this:
  ```
  config :app_name, __MODULE__,
    host: "xxxxxxxxx.iot.ap-southeast-1.amazonaws.com",
    port: 8883,
    client_id: "xxxxxxx",
    ca_cert: "config/certs/root-CA.crt",
    client_cert: "config/certs/xxxxxxxxxx-certificate.pem.crt",
    private_key: "config/certs/xxxxxxxxxx-private.pem.key",
    mqttc_opts: []
  ```

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where pid is the pid of the server.
  Use `pid` with other functions defined in this module.

  If the server could not start, the process is terminated and the function returns
  `{:error, reason}`, where reason is the error reason.
  """
  @spec start_link(GenEvent.manager, atom | [{atom, any}], Keyword.t) :: GenServer.on_start
  def start_link(event_manager, mqttc_options_or_app_name \\ :aws, process_options \\ [])
  def start_link(event_manager, mqttc_options, process_options) when is_list(mqttc_options) and is_list(process_options) do
    # Event_manager is required to emit events. Use: {:ok, event_manager} = GenEvent.start_link([])
    GenServer.start_link(__MODULE__, {event_manager, mqttc_options}, process_options)
  end
  def start_link(event_manager, app_name, process_options) when is_atom(app_name) and is_list(process_options) do
    # Get configuration from environment set by config.exs
    mix_config_options = Application.get_env(app_name, __MODULE__)
    mqttc_options = [
      host: to_char_list(mix_config_options[:host]),
      port: mix_config_options[:port],
      client_id: mix_config_options[:client_id],
      clean_sess: true,
      keepalive: 60,
      connack_timeout: 30,
      reconnect: {3, 60},
      logger: :info,
      ssl: [
        cacertfile: to_char_list(mix_config_options[:ca_cert]),
        certfile: to_char_list(mix_config_options[:client_cert]),
        keyfile: to_char_list(mix_config_options[:private_key])
      ]
    ]

    # Let :emqttc process resubscribe topics when reconnected
    mqttc_options = [:auto_resub | mqttc_options]

    # Let mqttc_opt configuration override mqttc_options
    mqttc_opts = mix_config_options[:mqttc_opts]
    if is_list(mqttc_opts), do: mqttc_options = mqttc_opts ++ mqttc_options

    start_link(event_manager, mqttc_options, process_options)
  end

  @doc """
  Get the event_manager of this client
  """
  @spec get_event_manager(GenServer.server) :: GenEvent.manager
  def get_event_manager(pid) do
    GenServer.call(pid, :get_event_manager)
  end

  @doc """
  Fetch the event_manager of this client
  """
  @spec fetch_event_manager(GenServer.server) :: {:ok, GenEvent.manager} | {:error, term}
  def fetch_event_manager(pid) do
    try do
      event_manager = GenServer.call(pid, :get_event_manager)
      {:ok, event_manager}
    catch
      :exit, e -> {:error, e}
    end
  end

  @doc """
  Register interest in the Thing Shadow named `thing_name`. The thingShadow process will subscribe to any applicable topics, and will fire events for the Thing Shadow until `unregister/2` is called with `thing_name`. `options` can contain the following arguments to modify how this Thing Shadow is processed:

  `ignore_seltas`: set to `true` to not subscribe to the delta sub-topic for this Thing Shadow; used in cases where the application is not interested in changes (e.g. update only.) (default `false`)
  `persistent_subscribe`: set to `false` to unsubscribe from all operation sub-topics while not performing an operation (default `true`)
  `discard_stale`: set to `false` to allow receiving messages with old version numbers (default `true`)
  `enable_versioning`: set to `true` to send version numbers with shadow updates (default `true`)

  The `persistent_subscribe` argument allows an application to get faster operation responses at the expense of potentially receiving more irrelevant response traffic (i.e., response traffic for other clients who have registered interest in the same Thing Shadow). When persistent_subscribe is set to `false`, operation sub-topics are only subscribed to during the scope of that operation; note that in this mode, update, get, and delete operations will be much slower; however, the application will be less likely to receive irrelevant response traffic.

  The `discard_stale` argument allows applications to receive messages which have obsolete version numbers. This can happen when messages are received out-of-order; applications which set this argument to `false` should use other methods to determine how to treat the data (e.g. use a time stamp property to know how old/stale it is).

  If `enable_versioning` is set to `true`, version numbers will be sent with each operation. AWS IoT maintains version numbers for each shadow, and will reject operations which contain the incorrect version; in applications where multiple clients update the same shadow, clients can use versioning to avoid overwriting each other's changes.
  """
  @spec register(GenServer.server, String.t, Keyword.t) :: :ok | {:error, any}
  def register(pid, thing_name, options \\ [qos: 1]) when is_binary(thing_name) and is_list(options) do
    GenServer.call(pid, {:thing_register, thing_name, options})
  end

  @doc """
  Unregister interest in the Thing Shadow named `thing_name`. The thingShadow process will unsubscribe from all applicable topics and no more events will be fired for thing_name.
  """
  @spec unregister(GenServer.server, String.t) :: :ok | {:error, any}
  def unregister(pid, thing_name) when is_binary(thing_name) do
    GenServer.call(pid, {:thing_unregister, thing_name})
  end

  @doc """
  Update the Thing Shadow named `thing_name` with the state specified in the object `shadow_state_object`. `thing_name` must have been previously registered using `register/3`. The thingShadow process will subscribe to all applicable topics and publish `shadow_state_object` on the update sub-topic.

  If the operation is in progress, this function returns `{:ok, client_token}`.
  `client_token` is a unique value associated with the update operation. When a 'status' or 'timeout' event is emitted, the client_token will be supplied as one of the parameters, allowing the application to keep track of the status of each operation. The caller may create their own client_token value; if `shadow_state_object` contains a client_token property, that will be used rather than the internally generated value. Note that it should be of atomic type (i.e. numeric or string). This function returns `nil` if an operation is already in progress.

  `operation_timeout` (milliseconds). If no accepted or rejected response to a thing operation is received within this time, subscriptions to the accepted and rejected sub-topics for a thing are cancelled.
  """
  @spec update(GenServer.server, String.t, %{atom => any}) :: {:ok, binary} | {:error, any}
  def update(pid, thing_name, shadow_state_object, operation_timeout \\ 10000) when is_binary(thing_name) and is_map(shadow_state_object) and operation_timeout >= 0 do
    #shadow_state_object = %{
    #  state: %{
    #    reported: %{
    #      "awsSqsSyncLastMessageId" => "3c52e73a-284c-4dc1-80d6-2d01d64f5b35"
    #    }
    #  }
    #}

    GenServer.call(pid, {:thing_operation, :update, thing_name, shadow_state_object, operation_timeout})
  end
  
  @doc """
  Get the current state of the Thing Shadow named `thing_name`, which must have been previously registered using `register/3`. The thingShadow process will subscribe to all applicable topics and publish on the get sub-topic.

  If the operation is in progress, this function returns `{:ok, client_token}`.
  `client_token` is a unique value associated with the get operation. When a 'status or 'timeout' event is emitted, the client_token will be supplied as one of the parameters, allowing the application to keep track of the status of each operation. The caller may supply their own client_token value (optional); if supplied, the value of client_token will be used rather than the internally generated value. Note that this value should be of atomic type (i.e. numeric or string). This function returns `nil` if an operation is already in progress.

  `operation_timeout` (milliseconds). If no accepted or rejected response to a thing operation is received within this time, subscriptions to the accepted and rejected sub-topics for a thing are cancelled.
  """
  @spec get(GenServer.server, String.t, String.t) :: {:ok, binary} | {:error, any}
  def get(pid, thing_name, client_token \\ "", operation_timeout \\ 10000) when is_binary(thing_name) and is_binary(client_token) and operation_timeout >= 0 do
    shadow_state_object = if (client_token == ""), do: %{}, else: %{clientToken: client_token}
    GenServer.call(pid, {:thing_operation, :get, thing_name, shadow_state_object, operation_timeout})
  end

  @doc """
  Delete the Thing Shadow named `thing_name`, which must have been previously registered using `register/3`. The thingShadow process will subscribe to all applicable topics and publish on the delete sub-topic.

  If the operation is in progress, this function returns `{:ok, client_token}`.
  `client_token` is a unique value associated with the delete operation. When a 'status' or 'timeout' event is emitted, the client_token will be supplied as one of the parameters, allowing the application to keep track of the status of each operation. The caller may supply their own client_token value (optional); if supplied, the value of client_token will be used rather than the internally generated value. Note that this value should be of atomic type (i.e. numeric or string). This function returns `nil` if an operation is already in progress.

  `operation_timeout` (milliseconds). If no accepted or rejected response to a thing operation is received within this time, subscriptions to the accepted and rejected sub-topics for a thing are cancelled.
  """
  @spec delete(GenServer.server, String.t, String.t) :: {:ok, binary} | {:error, any}
  def delete(pid, thing_name, client_token \\ "", operation_timeout \\ 10000) when is_binary(thing_name) and is_binary(client_token) and operation_timeout >= 0 do
    shadow_state_object = if (client_token == ""), do: %{}, else: %{clientToken: client_token}
    GenServer.call(pid, {:thing_operation, :get, thing_name, shadow_state_object, operation_timeout})
  end

  @doc """
  Identical to the `:emqttc.publish/3` method, with the restriction that the topic may not represent a Thing Shadow. This method allows the user to publish messages to topics on the same connection used to access Thing Shadows.
  """
  @spec publish(GenServer.server, String.t, any, Keyword.t) :: :ok | {:error, any}
  def publish(pid, topic, payload, options \\ [qos: 0]) when is_binary(topic) and is_list(options) do
    GenServer.call(pid, {:thing_publish, topic, payload, options})
  end

  @doc """
  Identical to the `:emqttc.subscribe/2` method, with the restriction that the topic may not represent a Thing Shadow. This method allows the user to subscribe to messages from topics on the same connection used to access Thing Shadows.
  """
  @spec subscribe(GenServer.server, String.t | {String.t, atom | integer} | [{String.t, atom | integer}], Keyword.t) :: :ok | {:error, any}
  def subscribe(pid, topics, options \\ [qos: 0])
  def subscribe(pid, topics_with_qos = [ {topic, qos} | _ ], options) when is_binary(topic) and (is_atom(qos) or is_integer(qos)) and is_list(options) do
    GenServer.call(pid, {:thing_subscribe, topics_with_qos, options})
  end
  def subscribe(pid, topic_with_qos = {topic, qos}, options) when is_binary(topic) and (is_atom(qos) or is_integer(qos)) and is_list(options) do
    GenServer.call(pid, {:thing_subscribe, topic_with_qos, options})
  end
  def subscribe(pid, topic, options) when is_binary(topic) and is_list(options) do
    if options[:qos] == nil do
      {:error, "options is missing qos"}
    else
      GenServer.call(pid, {:thing_subscribe, topic, options})
    end
  end

  @doc """
  Identical to the `:emqttc.unsubscribe/1` method, with the restriction that the topic may not represent a Thing Shadow. This method allows the user to unsubscribe from topics on the same used to access Thing Shadows.
  """
  @spec unsubscribe(GenServer.server, String.t | [String.t]) :: :ok | {:error, any}
  def unsubscribe(pid, topics = [ topic | _ ]) when is_binary(topic) do
    GenServer.call(pid, {:thing_unsubscribe, topics})
  end
  def unsubscribe(pid, topic) when is_binary(topic) do
    GenServer.call(pid, {:thing_unsubscribe, topic})
  end

  @doc """
  Invokes the `GenServer.stop/3` method on the thingShadow process. This causes `terminate/2` to be called and the MQTT connection owned by the thingShadow process to be disconnected. The force parameters is optional and identical in function to the `:shutdown` reason parameter in the `GenServer.stop/3` method.
  """ 
  @spec stop(GenServer.server, atom) :: :ok
  def stop(pid, reason \\ :normal)
  def stop(pid, true) do
    GenServer.stop(pid, :force, :infinity)
  end
  def stop(pid, reason) do
    GenServer.stop(pid, reason, :infinity)
  end



  ## GenServer Callbacks ##

  @doc """
  Responsible for connecting to the MQTT broker
  """
  def init({event_manager, mqttc_options}) do
    # GenEvent.manager needs to be monitored (on top of supervision).
    # Monitor means that ThingShadow.Client process should stop when its event_manager exits/crashes.
    # However, the event_manager should not stop if the ThingShadow.Client process crashes.
    _monitor_ref = Process.monitor(event_manager)

    try do
      {:ok, client} = :emqttc.start_link(mqttc_options)
      {:ok, %{mqttc: client, event_manager: event_manager, thing_shadows: %{}, client_id: mqttc_options[:client_id], seq: 0 } }

    rescue
      e -> {:stop, e}
    end

  end


  @doc """
  Responsible for handling thingshadow register-interest calls

  ## Options ##
  * qos: set to the desired QoS level :qos0 or :qos1 for the MQTT messages (default :qos0)
  * ignore_deltas: set to true to not subscribe to the delta sub-topic for this Thing Shadow; used in cases where the application is not interested in changes (e.g. update only.) (default false)
  * persistent_subscribe: set to false to unsubscribe from all operation sub-topics while not performing an operation (default true)
  * discard_stale: set to false to allow receiving messages with old version numbers (default true)
  * enable_versioning: set to true to send version numbers with shadow updates (default true)
  """
  def handle_call({:thing_register, thing_name, opts}, _from, state = %{mqttc: client, thing_shadows: thing_shadows}) when is_binary(thing_name) and is_list(opts) do
    # DONE: Implement version keeping and options[:discard_stale]
    # DONE: Delay subscribe to during update/delete operation only, if options[:persistent_subscribe]
    # DONE: Send version numbers with shadow updates if options[:enable_versioning]
    # DONE: Do not subscribe to delta topics if options[:ignore_deltas]

    ignore_deltas = Keyword.get(opts, :ignore_deltas, false)
    persistent_subscribe = Keyword.get(opts, :persistent_subscribe, true)
    discard_stale = Keyword.get(opts, :discard_stale, true)
    enable_versioning = Keyword.get(opts, :enable_versioning, true)
    qos = Keyword.get(opts, :qos, :qos0)

    current_thing = %{
      operation_timers: %{},
      persistent_subscribe: persistent_subscribe,
      discard_stale: discard_stale,
      enable_versioning: enable_versioning,
      qos: qos
    }

    new_state = %{state | thing_shadows: Map.put_new(thing_shadows, thing_name,current_thing) }

    # Exclude delta topic if ignore_delta == true
    subscribe_result = case ignore_deltas do
      false ->
        case persistent_subscribe do
          true ->
            handle_subscriptions(client, {:subscribe, thing_name, [:update, :get, :delete], [:delta, :accepted, :rejected]}, current_thing)
          false ->
            handle_subscriptions(client, {:subscribe, thing_name, [:update], [:delta]}, current_thing)
        end
        
      true ->
        case persistent_subscribe do
          true ->
            handle_subscriptions(client, {:subscribe, thing_name, [:update, :get, :delete], [:accepted, :rejected]}, current_thing)
          false ->
            # Do nothing
            {:ok, :noop}
        end
    end

    case subscribe_result do
      :ok ->
        # Update to new state on ok
        {:reply, :ok, new_state}

      {:ok, _} ->
        # Update to new state on ok
        {:reply, :ok, new_state}

      :error ->
        # Keep previous state on error
        {:reply, {:error, :unknown}, state}

      {:error, reason} ->
        # Keep previous state on error
        {:reply, {:error, reason}, state}
    end
  end

  @doc """
  Responsible for handling thingshadow update/get/delete operation-requests for a registered thing
  """
  def handle_call({:thing_operation, operation, thing_name, shadow_state_object, operation_timeout}, _from, state = %{mqttc: client, thing_shadows: thing_shadows, client_id: client_id, seq: seq}) when is_atom(operation) and is_binary(thing_name) do
    case thing_shadows do
      %{^thing_name => current_thing} ->
        # Generate client_token if missing from shadow_state_object
        client_token = shadow_state_object[:clientToken] || shadow_state_object["clientToken"] || "#{client_id}-#{seq}"
        shadow_state_object = Map.put_new(shadow_state_object, :clientToken, client_token)

        # Subscribe to response topics (if persistent_subscribe is false)
        case handle_persistent_subscriptions(client, {:subscribe, thing_name, [operation], [:accepted, :rejected]}, current_thing) do
          {:ok, _} ->
            # After a period of time, we are no longer interested in the accepted/rejected response, so we unsubscribe (if persistent_subscribe is false)
            operation_timer = Process.send_after(self(), {:thing_operation_timeout, thing_name, operation, client_token}, operation_timeout)

            publish_topic = build_thing_shadow_topic(thing_name, operation)
            case publish_shadow_state_to_topic(client, publish_topic, shadow_state_object, current_thing) do
              :ok ->
                # Add client_token to operation_timers in current_thing
                current_thing = current_thing |> Map.update(:operation_timers, %{client_token => operation_timer}, fn current_operation_timers ->
                  Map.put_new(current_operation_timers, client_token, operation_timer)
                end)
                # Update state of operation_timers in current_thing and increment seq
                thing_shadows = %{thing_shadows | thing_name => current_thing}
                {:reply, {:ok, client_token}, %{state | thing_shadows: thing_shadows, seq: seq+1 } }

              other ->
                # Would rather not reuse sequence number even on publish error, 
                # in case message reaches broker eventually, causing AWS IoT responses with same client_token
                {:reply, other, %{state | seq: seq+1 }}
            end

          other ->
            {:reply, other, state}
        end

      _no_match ->
        {:reply, {:error, "Attempting to #{operation} unknown thing: #{thing_name}. Please register beforehand."}, state }
    end
  end

  @doc """
  Responsible for handling publish requests on non-thing topics
  """
  def handle_call({:thing_publish, topic, payload, opts}, _from, state = %{mqttc: client}) when is_binary(topic) do
    publish_result = :emqttc.publish(client, topic, payload, opts)
    {:reply, publish_result, state}
  end

  @doc """
  Responsible for handling subscribe requests on non-thing topics
  """
  def handle_call({:thing_subscribe, topics, _opts}, _from, state = %{mqttc: client}) when is_list(topics) do
    subscribe_result = :emqttc.subscribe(client, topics)
    {:reply, subscribe_result, state}
  end
  def handle_call({:thing_subscribe, topic, _opts}, _from, state = %{mqttc: client}) when is_tuple(topic) do
    subscribe_result = :emqttc.subscribe(client, topic)
    {:reply, subscribe_result, state}
  end
  def handle_call({:thing_subscribe, topic, opts}, _from, state = %{mqttc: client}) when is_binary(topic) do
    subscribe_result = :emqttc.subscribe(client, topic, opts[:qos])
    {:reply, subscribe_result, state}
  end

  @doc """
  Responsible for handling unsubscribe requests on non-thing topics
  """
  def handle_call({:thing_unsubscribe, topics}, _from, state = %{mqttc: client}) when is_list(topics) do
    unsubscribe_result = :emqttc.unsubscribe(client, topics)
    {:reply, unsubscribe_result, state}
  end
  def handle_call({:thing_unsubscribe, topic}, _from, state = %{mqttc: client}) when is_binary(topic) do
    unsubscribe_result = :emqttc.subscribe(client, topic)
    {:reply, unsubscribe_result, state}
  end

  @doc """
  Responsible for handling :get_event_manager requests
  """
  def handle_call(:get_event_manager, _from, state = %{event_manager: event_manager}) do
    {:reply, event_manager, state}
  end
  

  @doc """
  Responsible for receiving MQTT broker connected event from mqttc client
  """
  def handle_info({:mqttc, client, :connected}, state = %{mqttc: client, event_manager: handlers}) do
    IO.puts "MQTT client #{inspect(client)} is connected"

    GenEvent.ack_notify(handlers, {:connect, self})
    {:noreply, state}
  end

  @doc """
  Responsible for receiving MQTT broker disconnected event from mqttc client
  """
  def handle_info({:mqttc, client, :disconnected}, state = %{mqttc: client, event_manager: handlers}) do
    IO.puts "MQTT client #{inspect(client)} is disconnected"

    GenEvent.ack_notify(handlers, {:disconnect, self})
    {:noreply, state}
  end

  @doc """
  Responsible for receiving event_manager down notification.
  ThingShadow.Client process should stop when event_manager is dead.
  """
  def handle_info({:DOWN, _ref, :process, {event_manager, _node}, _reason}, state = %{event_manager: event_manager} ) do
    {:stop, :event_manager_down, state}
  end

  @doc """
  Responsible for receiving operation timeout messages
  """
  def handle_info({:thing_operation_timeout, thing_name, operation, client_token}, state = %{mqttc: client, event_manager: handlers, thing_shadows: thing_shadows}) do
    case thing_shadows do
      %{^thing_name => current_thing} ->
        # Unsubscribe from response topics (if persistent_subscribe is false)
        handle_persistent_subscriptions(client, {:unsubscribe, thing_name, [operation], [:accepted, :rejected]}, current_thing)
        # Notify timeout event handlers
        GenEvent.ack_notify(handlers, {:timeout, thing_name, client_token})
        # Remove client_token from operation_timers in current_thing
        current_thing = current_thing |> Map.update(:operation_timers, %{}, fn current_operation_timers ->
          current_operation_timers |> Map.delete(client_token)
        end)
        # Update state of operation_timers in current_thing
        thing_shadows = %{thing_shadows | thing_name => current_thing}
        {:noreply, %{state | thing_shadows: thing_shadows}}

      _no_match ->
        {:noreply, state}
    end
  end

  @doc """
  Responsible for receiving MQTT messages from mqttc client
  """
  def handle_info({:publish, topic, payload}, state) do
    IO.puts "Message from #{topic}: #{payload}"

    # Handle topics by pattern-matching
    topic |> String.split("/", parts: 6) |> handle_topic_message(payload, state)
  end

  @doc """
  Responsible for receiving MQTT messages from thingshadow topics of registered things
  """
  def handle_topic_message(topic_iolist = ["$aws", "things", thing_name, "shadow", "update", "delta"], payload, state = %{event_manager: handlers, thing_shadows: thing_shadows}) when is_binary(thing_name) do
    # Handle delta response message
    case thing_shadows do
      %{^thing_name => current_thing} ->
        case Poison.Parser.parse(payload) do
          {:ok, shadow_state_object} ->
            _client_token = shadow_state_object["clientToken"] || shadow_state_object[:clientToken]
            version = shadow_state_object["version"] || shadow_state_object[:version]

            case update_version_in_thing(current_thing, version, :update) do
              nil ->
                # Do nothing as message is to be discarded
                {:noreply, state}
              current_thing ->
                # Notify delta event handlers
                GenEvent.ack_notify(handlers, {:delta, thing_name, shadow_state_object})
                # Update state of version in current_thing
                thing_shadows = %{thing_shadows | thing_name => current_thing}
                {:noreply, %{state | thing_shadows: thing_shadows}}
            end

          {:error, _reason} ->
            {:noreply, state}
        end

      _no_match ->
        GenEvent.ack_notify(handlers, {:message, to_string(topic_iolist), payload})
        {:noreply, state}
    end
  end
  def handle_topic_message(topic_iolist = ["$aws", "things", thing_name, "shadow", operation, status], payload, state = %{mqttc: client, event_manager: handlers, thing_shadows: thing_shadows}) when is_binary(thing_name) and is_binary(operation) and is_binary(status) do
    # Handle accepted/rejected response message
    case thing_shadows do
      %{^thing_name => current_thing} ->
        # Convert string to atoms
        operation = case operation do
          "update" -> :update
          "get" -> :get
          "delete" -> :delete
        end
        status = case status do
          "accepted" -> :accepted
          "rejected" -> :rejected
        end

        case Poison.Parser.parse(payload) do
          {:ok, shadow_state_object} ->
            client_token = shadow_state_object["clientToken"] || shadow_state_object[:clientToken]
            version = shadow_state_object["version"] || shadow_state_object[:version]

            case update_version_in_thing(current_thing, version, operation) do
              nil ->
                # Do nothing as message is to be discarded
                {:noreply, state}

              current_thing = %{operation_timers: _current_operation_timers = %{^client_token => _} } ->
                # Cancel operation_timeout timer, and Remove client_token from operation_timers in current_thing
                current_thing = current_thing |> Map.update(:operation_timers, %{}, fn current_operation_timers ->
                  {operation_timer, new_operation_timers} = current_operation_timers |> Map.pop(client_token)
                  if (operation_timer != nil), do: Process.cancel_timer(operation_timer)
                  new_operation_timers
                end)
                # Unsubscribe if persistent_subscribe is false
                handle_persistent_subscriptions(client, {:unsubscribe, thing_name, [operation], [:accepted, :rejected]}, current_thing)
                # Notify status event handlers
                GenEvent.ack_notify(handlers, {:status, thing_name, status, client_token, shadow_state_object})
                # Update state of version and operation_timers in current_thing
                thing_shadows = %{thing_shadows | thing_name => current_thing}
                {:noreply, %{state | thing_shadows: thing_shadows}}

              current_thing when status == :accepted and operation != :get ->
                # This operation is not made from this client
                GenEvent.ack_notify(handlers, {:foreign_state_change, thing_name, operation, shadow_state_object})
                # Update state of version in current_thing
                thing_shadows = %{thing_shadows | thing_name => current_thing}
                {:noreply, %{state | thing_shadows: thing_shadows}}

              current_thing when true ->
                # Just update the version state as this operation is not made from this client, and is not relevant to local event handlers
                thing_shadows = %{thing_shadows | thing_name => current_thing}
                {:noreply, %{state | thing_shadows: thing_shadows}}
            end

          {:error, _reason} ->
            {:noreply, state}
        end

      _no_match ->
        GenEvent.ack_notify(handlers, {:message, to_string(topic_iolist), payload})
        {:noreply, state}
    end
  end
  def handle_topic_message(topic_iolist, payload, state = %{event_manager: handlers}) when is_list(topic_iolist) do
    # Handle messages from other topics
    GenEvent.ack_notify(handlers, {:message, to_string(topic_iolist), payload})
    {:noreply, state}
  end

  def terminate(reason, state = %{mqttc: client} ) do
    if Process.alive?(client) do
      :ok = :emqttc.disconnect(client)
    end
    super(reason, state)
  end



  ## Helper Functions ##

  ### Handles subscribe and unsubscribe actions on thingshadow topics
  defp handle_subscriptions(client, {:subscribe, thing_name, operations, statii}, _thing_opts = %{qos: qos}) when is_binary(thing_name) do
    topics = build_thing_shadow_topics(thing_name, operations, statii)
    topics_with_qos = topics |> Enum.map(fn topic -> {topic, qos} end)
    :emqttc.subscribe(client, topics_with_qos)

    # Bug filed under https://github.com/emqtt/emqttc/issues/37
    # :emqttc.sync_subscribe(client, topics_with_qos)
  end
  defp handle_subscriptions(client, {:unsubscribe, thing_name, operations, statii}, _thing_opts) when is_binary(thing_name) do
    topics = build_thing_shadow_topics(thing_name, operations, statii)
    :emqttc.unsubscribe(client, topics)
  end

  ### Handles persistent subscribe and unsubscribe actions on thingshadow topics
  defp handle_persistent_subscriptions(_client, _topic_params = {_, thing_name, _operations, _statii}, _thing_opts = %{persistent_subscribe: true}) when is_binary(thing_name) do
    {:ok, :noop}
  end
  defp handle_persistent_subscriptions(client, topic_params = {_, thing_name, _operations, _statii}, thing_opts = %{persistent_subscribe: false}) when is_binary(thing_name) do
    handle_subscriptions(client, topic_params, thing_opts)
  end

  ### Publish thingshadow shadow_state_object to MQTT topic with or without versioning
  defp publish_shadow_state_to_topic(client, topic, shadow_state_object, _current_thing = %{qos: qos, enable_versioning: true, version: version}) when is_binary(topic) do
    # Enable_versioning is true and version is available
    shadow_state_object = Map.put_new(shadow_state_object, :version, version)

    # Encode shadow_state_object to json, and then Asynchronous publish to topic. If qos1, emqttc will  queue the resend.
    shadow_state_object_json = shadow_state_object |> Poison.Encoder.encode([]) |> to_string
    :emqttc.publish(client, topic, shadow_state_object_json, qos)
  end
  defp publish_shadow_state_to_topic(client, topic, shadow_state_object, _current_thing = %{qos: qos, enable_versioning: _}) when is_binary(topic) do
    # Version is unavailable or Enable_versioning is false
    # Encode shadow_state_object to json, and then Asynchronous publish to topic. If qos1, emqttc will queue the resend.
    shadow_state_object_json = shadow_state_object |> Poison.Encoder.encode([]) |> to_string
    :emqttc.publish(client, topic, shadow_state_object_json, qos)
  end

  ### Update version in thing map based on whether `new_version` is indeed newer than `current_version`
  defp update_version_in_thing(current_thing = %{version: current_version, discard_stale: _}, new_version, _operation = :delete) when new_version <= current_version do
    # New_version is older than current_version, but operation is delete
    # Do not discard no matter the value of discard_stale option.
    current_thing
  end
  defp update_version_in_thing(current_thing = %{version: current_version, discard_stale: false}, new_version, _operation) when new_version <= current_version do
    # New_version is older than current_version, but discard_stale option is false
    # Do not discard as discard_stale = false
    current_thing
  end
  defp update_version_in_thing(_current_thing = %{version: current_version, discard_stale: true}, new_version, _operation) when new_version <= current_version do
    # New_version is older than current_version, and discard_stale option is true
    # Indicate discard new state by returning nil
    nil
  end
  defp update_version_in_thing(current_thing = %{version: current_version}, new_version, _operation) when new_version > current_version do
    # New_version is newer than current_version
    %{current_thing | version: new_version}
  end
  defp update_version_in_thing(current_thing, new_version, _operation) do
    # Current_version is undefined
    Map.put_new(current_thing, :version, new_version)
  end

  @doc """
  Builds thingshadow topic according to AWS Spec
  """
  def build_thing_shadow_topic(thing_name, operation, status \\ nil)
  def build_thing_shadow_topic(thing_name, operation = :update, status = :delta) do
    "$aws/things/#{thing_name}/shadow/#{operation}/#{status}"
  end
  def build_thing_shadow_topic(_thing_name, _operation, _status = :delta) do
    # Delta is only valid for update operation.
    nil
  end
  def build_thing_shadow_topic(thing_name, operation, _status = nil) do
    # Used to build a topic to publish to
    "$aws/things/#{thing_name}/shadow/#{operation}"
  end
  def build_thing_shadow_topic(thing_name, operation, status) do
    # Used to build a topic to subscribe to
    "$aws/things/#{thing_name}/shadow/#{operation}/#{status}"
  end

  @doc """
  Builds multiple thingshadow topics at once and returns a flat list
  """
  def build_thing_shadow_topics(thing_name, operations, statii) when is_binary(thing_name) and is_list(operations) and is_list(statii) do
    Enum.flat_map(operations, fn operation ->
      statii
      |> Enum.map(&build_thing_shadow_topic(thing_name, operation, &1))
      |> Enum.filter(&(&1))
    end)
  end

end