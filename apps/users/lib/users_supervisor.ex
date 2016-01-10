defmodule Users.UserSupervisor do
  use Supervisor
  require Logger
  ## simple one for one supervisor for Users.User processes

  def start_link opt \\ [] do
    Logger.info "start_link"
    Supervisor.start_link(__MODULE__, :ok, opt)
  end

  def start_user(supervisor, user_id, stream_ref) do
    Supervisor.start_child(supervisor, [user_id, stream_ref])
  end

  def start_user(supervisor, user_state) do
    Supervisor.start_child(supervisor, [user_state])
  end

  def init(:ok) do
    Logger.info "init"
    children = [ worker(Users.User, [], restart: :temporary) ]
    supervise(children, strategy: :simple_one_for_one)
  end
end
