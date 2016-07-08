defmodule Aws.Iot.ThingShadow.Supervisor do
  
  @moduledoc ~S"""
  Module-based supervisor for `ThingShadow.Client`.
  Ensures that event handling and dispatch can survive the lifetime of `ThingShadow.Client`.

  You may want to use a module-based supervisor if:
  - You need to perform some particular action on supervisor initialization, like setting up an ETS table.
  - You want to perform partial hot-code swapping of the tree. For example, if you add or remove children, the module-based supervision will add and remove the new children directly, while dynamic supervision requires the whole tree to be restarted in order to perform such swaps.
  """

  use Supervisor

  @supervision_strategy :rest_for_one

  @doc """
  Starts the supervisor
  """
  def start_link(client_name \\ Aws.Iot.ThingShadow.Client, opts \\ [])
  def start_link(client_name, opts) do
    supervisor_name = name_concat(client_name, "Supervisor")
    # To start the supervisor, the init/1 callback will be invoked in the given module, with init_args as its argument
    Supervisor.start_link(__MODULE__, [client_name, opts], name: supervisor_name)
  end

  @doc """
  Callback invoked to start the supervisor and during hot code upgrades.
  """
  def init([client_name, opts]) when is_list(opts) do
    mqttc_options_or_app_name = Keyword.get(opts, :mqtt, nil) || Keyword.get(opts, :app_config, :aws_iot)

    event_manager_name = name_concat(client_name, "EventManager")

    # ThingShadow worker must be able to lookup its GenEvent.manager by name, not by pid.
    # This is so that when GenEvent.manager is restarted with a new pid, the reference is still valid.
    children = [
      worker(GenEvent, [[name: event_manager_name]]),
      worker(Aws.Iot.ThingShadow.Client, [event_manager_name, mqttc_options_or_app_name, [name: client_name]])
    ]

    # Init must return a supervisor spec
    supervise(children, strategy: @supervision_strategy)
  end

  # Handles more cases than `Module.concat/2`
  defp name_concat(name1, name2) when is_binary(name2) do
    case name1 do
      {:via, via_module, name} -> {:via, via_module, "#{name}.#{name2}"}
      {:global, name} -> {:global, "#{name}.#{name2}"}
      name when is_atom(name) -> :"#{name}.#{name2}"
    end
  end
  defp name_concat(name1, name2) when is_atom(name2) do
    name2 = tl Module.split(Module.concat(name1, name2))
    name_concat(name1, name2)
  end

end