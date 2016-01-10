defmodule Users.UserServer do
  use GenServer
  require Logger

  alias Users.UserSupervisor
  alias Media.StreamServer

  def start_link(user_sup, opt \\ []) do
    Logger.info "start_link"
    GenServer.start_link(__MODULE__, {:ok, user_sup}, opt)
  end

  # TODO redo with lookup to be a login/logout thing. login would increase a counter
  # and logout would decrease. when counter == 0. the user is put to sleep.

  # perhaps not needed could use Ets instead
  # possible race condition if process dies after this has returned a pid
  def lookup([user_name]), do: lookup(user_name)
  def lookup(user_name),   do: GenServer.call(__MODULE__, {:lookup, user_name})

  #ISSUE: using __MODULE__ in GenServer.call implies that the start_link
  #has opt containging name: matching this module name
  def create([user_name]), do: create(user_name)
  def create(user_name)   do
    GenServer.call(__MODULE__, {:create, user_name})
  end

  def get_active_user_names(),  do: GenServer.call(__MODULE__, :active)

  def subscribe_new_user_notice(subscriber) do
    GenServer.cast(__MODULE__, {:subscribe, subscriber})
  end

  def subscribe_new_user_notice(), do: subscribe_new_user_notice(self)

  def unsubscribe(subscriber), do:
    GenServer.cast(__MODULE__, {:unsubscribe, subscriber})

  def login(name),  do: GenServer.call(__MODULE__, {:login, name})
  def logout(name), do: GenServer.call(__MODULE__, {:logout, name})
  ## monitor/handle users
  # save to ets on user exit
  # restore from ets on user awake
  # restore from ets on user respawn after crash
  # remonitor user pids when self is respawned

  ##----------------------------------------------------------------------##
  def init {:ok, user_sup} do
    Logger.info "init"
    {:ok, %{:ref2name  => %{}, # ref => name
            :name2pid  => %{}, # name => pid
            :user_sup  => user_sup,
            :subscribers => [],
            :logged_out => %{}} } # name => previous state
  end

  def handle_call({:lookup, user_name}, _from, %{:name2pid => name2pid}=state) do
    #TODO: handle logged out users
    reply = case Map.get(name2pid, user_name) do
      nil -> {:error, {:unmapped_name, user_name}}
      pid -> {:ok, pid}
    end
    {:reply, reply, state}
  end

  def handle_call({:login, name}, _from, %{:logged_out => logged_out} = state) do
    #!ISSUE: nested case, refactor!
    {reply, new_state} = case Map.get(logged_out, name) do
      nil ->
        Logger.info "user not logged out"
        case Map.get(state.name2pid, name) do
          nil ->
            Logger.info "no such user"
            {pid, new_state} = spawn_user(name, state)
            {{:ok, pid}, new_state}
          pid ->
            Logger.info "user already logged in"
            #TODO: increase logged in counter matching #{counter, pid} ->
            {{:ok, pid}, state}
        end
      user_state ->
        Logger.info "user logged out, log it in again"
        {pid, new_state} = spawn_user(name, user_state, state)
        {{:ok, pid}, new_state}
    end
    {:reply, reply, new_state}
  end

  def handle_call({:logout, name}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:create, user_name}, _from, state) do
    {reply, new_state} = create(user_name, state)
    {:reply, reply, new_state}
  end

  def handle_call(:active, _from, %{:name2pid => name2pid} = state) do
    {:reply, Map.keys(name2pid), state}
  end

  def handle_call(req, from, state) do
    Logger.warn "garbage -- #{inspect [req, from, state]}"
    {:reply, :error, state}
  end

  def handle_cast({:subscribe, pid}, %{:subscribers => subs} = state) do
    {:noreply, %{state | :subscribers => subs ++ [pid]}}
  end

  def handle_cast({:unsubscribe, pid}, %{:subscribers => subs} = state) do
    {:noreply, %{state | :subscribers => List.delete(subs, pid)}}
  end

  def handle_info({:notice, n}, state) do
    #TODO: handle info in notification {:notify, notification}
    for pid <- state.subscribers, do:
      #TODO: include notification in message
      send(pid, {:users_notify, n})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, :killed},
                  %{:ref2name => ref2name,
                    :name2pid => name2pid} = state) do
    {user_name, ref2name} = Map.pop(ref2name, ref)
    {_old_pid, name2pid} = Map.pop(name2pid, user_name)

    {:ok, pid} = UserSupervisor.start_user(state.user_sup, user_name)
    ref = Process.monitor(pid)

    {:noreply, %{state | :ref2name => Map.put(ref2name, ref, user_name),
                         :name2pid => Map.put(name2pid, user_name, pid)}}
  end

  def handle_info({:DOWN, ref, :process, pid, :shutdown},
                  %{:ref2name => ref2name,
                    :name2pid => name2pid} = state) do
    {user_name, ref2name} = Map.pop(ref2name, ref)
    {^pid, name2pid} = Map.pop(name2pid, user_name)

    {:noreply, %{state | :ref2name => ref2name,
                         :name2pid => name2pid}}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    Logger.warn "pid #{inspect pid} is DOWN with reason #{inspect reason}"
    {:noreply, state}
  end

  defp create(user_name, %{:ref2name => ref2name, :name2pid => name2pid} = state) do
    case Map.get(name2pid, user_name) do
      nil ->
        {pid, new_state} = spawn_user(user_name, state)
        {{:ok, pid}, new_state}
      _pid ->
        {{:error, :name_in_use}, state}
    end
  end

  defp spawn_user(user_name, state) do
    {:ok, stream} = StreamServer.create_stream
    {:ok, pid} = UserSupervisor.start_user(state.user_sup, user_name, stream)
    spawn_user_final(pid, user_name, state)
  end
  defp spawn_user(user_name, user_state, state) do
    {:ok, pid} = UserSupervisor.start_user(state.user_sup, user_state)
    spawn_user_final(pid, user_name, state)
  end
  defp spawn_user_final(pid, user_name, state) do
    ref = Process.monitor(pid)
    notice({:new_user, user_name})
    {pid, %{state | :ref2name => Map.put(state.ref2name, ref, user_name),
                    :name2pid => Map.put(state.name2pid, user_name, pid)}}
  end

  defp notice(n), do: send(self, {:notice, n})
end
