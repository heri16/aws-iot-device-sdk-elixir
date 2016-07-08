defmodule Aws.Iot.ThingShadow do

  @moduledoc ~S"""
  This module helps to make it easier to initialize a new `Aws.Iot.ThingShadow.Client` which:
  - Is supervised for automatic recovery
  - Has a GenEvent.manager that can survive the lifetime of the client process.
  - Has a GenEvent.handler that forwards event messages to other processes without blocking.

  `Aws.Iot.ThingShadow.Client` implements the AWS IoT ThingShadow Data Flow behaviour.
  It closely follows the logic from the official nodejs library, with minor deviations to adapt to Elixir Coding Conventions:
  https://github.com/aws/aws-iot-device-sdk-js/blob/master/thing/index.js
  """

  @root_supervisor Aws.Iot.Supervisor

  @doc """
  Intitializes a new `ThingShadow.Client` service, adds an event handler, and returns the client.

  The event handler will forward events to the processes specified in `event_handler_args`. 
  `event_handler_args` input should be a `Keyword` list containing one or more of the below:
  - `{:broadcast, {Phoenix.PubSub.server, topic}}`
  - `{:cast, GenServer.server}`
  - `{:call, GenServer.server}`

  The calling process will receive the message `{:gen_event_EXIT, handler, reason}` if the event handler is later deleted.
  For more information see `GenEvent.add_mon_handler/3`.

  ## Return values

  If successful, returns {:ok, thingshadow_client}.
  Use the `Aws.Iot.ThingShadow.Client` module to operate on the thingshadow_client.
  """
  @spec init_client([{:broadcast, {GenServer.server, binary}} | {:cast, GenServer.server} | {:call, GenServer.server}], GenServer.name, atom) :: {:ok, GenServer.server} | {:error, term}
  def init_client(event_handler_args, app_config \\ :aws_iot, client_name \\ Aws.Iot.ThingShadow) do
    import Supervisor.Spec, warn: false

    with {:ok, _client_supervisor} <- Supervisor.start_child(@root_supervisor, supervisor(Aws.Iot.ThingShadow.Supervisor, [client_name, [app_config: app_config]])),
      {:ok, client_event_manager} <- Aws.Iot.ThingShadow.Client.fetch_event_manager(client_name),
      :ok <- GenEvent.add_mon_handler(client_event_manager, Aws.Iot.ThingShadow.EventHandler, event_handler_args),
      do: {:ok, client_name}
  end

end