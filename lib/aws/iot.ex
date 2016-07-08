defmodule Aws.Iot do
  use Application

  @root_supervisor Aws.Iot.Supervisor

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      # Define workers and child supervisors to be supervised
      # worker(AwsIot.Worker, [arg1, arg2, arg3]),
      #supervisor(Aws.Iot.ThingShadow.Supervisor, [])
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: @root_supervisor]
    Supervisor.start_link(children, opts)
  end

end
