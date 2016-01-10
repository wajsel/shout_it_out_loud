defmodule Users do
  use Application
  require Logger

  @users_server_name Users.UserServer
  @users_supervisor_name Users.UserSupervisor

  def start(_type, _args) do
    Logger.info "start"
    import Supervisor.Spec, warn: false

    children = [
      supervisor(Users.UserSupervisor, [[name: @users_supervisor_name]]),
      worker(Users.UserServer, [@users_supervisor_name, [name: @users_server_name]])
    ]

    opts = [strategy: :one_for_one, name: Users.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
