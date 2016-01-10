defmodule ShouterApp do
  use Application

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      # Define workers and child supervisors to be supervised
      #worker(ShouterApp.ShoutServer, [ [name: ShouterApp.ShoutServer]])
      worker(Task.Supervisor, [ [name: ShouterApp.ShouterIF.Supervisor]])
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ShouterApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
# ============================================================================ #
defmodule ShouterApp.ShouterIF do

  alias Users.UserServer
  alias Users.User
  alias Media.StreamServer
  require Logger

  # TODO make macro api which creates a function call to handle below, with
  # correct data structure

  def handle(request) do
    Logger.info "handle : #{inspect request}"
    caller = self
    Task.Supervisor.async_nolink(ShouterApp.ShouterIF.Supervisor,
                                 fn -> do_handle(request, caller) end)
      |> Task.yield
  end

  # ------------------------------------------------------------------------- #
  #TODO: strange to take arguments as tuples and return map's !! unify API !!
  # ----------------- USERS ------------------------------------------------- #
  defp do_handle({:users, :list}, _caller_pid) do
    lst = UserServer.get_active_user_names
    {:ok, %{:users => lst}}
  end

  defp do_handle({:users, uid, :list_stream}, _caller_pid) do
    case UserServer.lookup uid do
      {:ok, user_pid} ->
        stream_ref = User.get_stream_ref user_pid
        stream_content = StreamServer.list_stream stream_ref
        {:ok, %{:stream => stream_content}}
      x ->
        Logger.warn "failed lookup user #{inspect uid}, error: #{inspect x}"
        {:error, x}
    end
  end

  defp do_handle({:users, uid, :list_stream_listeners}, _caller_pid) do
    case UserServer.lookup uid do
      {:ok, user_pid} ->
        Logger.debug "user_pid #{inspect user_pid}"
        stream_ref = User.get_stream_ref user_pid
        subscribers = Enum.map(StreamServer.listeners(stream_ref), fn {_,s} -> s end)
        {:ok, %{:listeners => subscribers}}
      x ->
        Logger.warn "failed lookup user #{inspect uid}, error: #{inspect x}"
        {:error, x}
    end
  end

  defp do_handle({:users, uid, :login, :subscribe_notices}, caller_pid) do
    case UserServer.login(uid) do
      {:ok, user_pid} ->
        stream_ref = User.get_stream_ref(user_pid)
        UserServer.subscribe_new_user_notice(caller_pid)
        StreamServer.subscribe_to_notices(stream_ref, caller_pid)
        {:ok, %{ :login => :ack, :shout_ref => stream_ref}}
      x ->
        Logger.warn "failed login user #{inspect uid}, error: #{inspect x}"
        {:error, x}
    end
  end
  defp do_handle({:users, uid, :login}, _caller_pid) do
    case UserServer.login(uid) do
      {:ok, user_pid} ->
        stream_ref = User.get_stream_ref user_pid
        {:ok, %{ :login => :ack, :shout_ref => stream_ref }}
      x ->
        Logger.warn "failed login user #{inspect uid}, error: #{inspect x}"
        {:error, x}
    end
  end

  defp do_handle({:users, uid, :add_media_to_stream, mid}, _caller_pid) do
    case UserServer.lookup uid do
      {:ok, user_pid} ->
        stream_ref = User.get_stream_ref user_pid
        StreamServer.add stream_ref, mid
        :ok
      x ->
        Logger.warn "failed lookup user #{inspect uid}, error: #{inspect x}"
        {:error, x}
    end
  end

  defp do_handle({:users, uid, :unsubscribe}, caller_pid) do
    case UserServer.lookup uid do
      {:ok, user_pid} ->
        #stream_ref = User.get_stream_ref user_pid
        StreamServer.unsubscribe user_pid, uid
        UserServer.unsubscribe caller_pid
        :ok
      x ->
        Logger.warn "failed lookup user #{inspect uid}, error: #{inspect x}"
        {:error, x}
    end
  end

  defp do_handle({:users, uid, :playback, ctrl}, _caller_pid) when ctrl in [:play, :pause, :next] do
    case UserServer.lookup uid do
      {:ok, user_pid} ->
        do_user_stream_ctrl(user_pid, ctrl)
        :ok
      x ->
        Logger.warn "failed lookup user #{inspect uid}, error: #{inspect x}"
        {:error, x}
    end
  end

  # ----------------- COLLECTION -------------------------------------------- #
  defp do_handle({:collection, :list}, _caller_pid) do
    media = Media.Collection.list
    {:ok, %{:collection => media}}
  end
  # ----------------- STREAMS ----------------------------------------------- #
  defp do_handle({:streams, stream_ref, :stream_info}, caller) do
    case StreamServer.stream_info stream_ref do
      {:ok, info} -> info
      e ->
        Logger.warn "error getting stream info for stream #{inspect stream_ref} : #{inspect e}"
        e
    end
  end
  defp do_handle({:streams, stream_ref, :subscribe_shouts, metadata}, caller) do
    case StreamServer.subscribe_to_shouts stream_ref, caller, metadata do
      :ok -> :ok
      e ->
        Logger.warn "error subscribe to stream #{inspect stream_ref} : #{inspect e}"
        e
    end
  end
  defp do_handle({:streams, stream_ref, :subscribe_notices}, caller) do
    StreamServer.subscribe_to_notices stream_ref, caller
    :ok
  end
  defp do_handle({:streams, stream_ref, :list}, _caller_pid) do
    stream_content = StreamServer.list_stream stream_ref
    {:ok, %{:stream => stream_content}}
  end

  defp do_handle({:streams, stream_ref, :playback, ctrl}, _caller_pid)
                  when ctrl in [:play, :pause, :next] do
    do_stream_ctrl stream_ref, ctrl
    :ok
  end

  defp do_handle({:streams, stream_ref, :list_stream_listeners}, _caller_pid) do
    subscribers = Enum.map(StreamServer.listeners(stream_ref), fn {_,s} -> s end)
    {:ok, %{:listeners => subscribers}}
  end

  defp do_handle(x, _caller_pid) do
    Logger.warn "unexpected: #{inspect x}"
    {:error, {:uknown_request, x}}
  end

  # ------------------------------------------------------------------------- #
  defp do_user_stream_ctrl(user_pid, ctrl) do
    #TODO: refactor, put more logic in UserServer? similar to StreamServer?
    stream_ref = User.get_stream_ref user_pid
    do_stream_ctrl stream_ref, ctrl
  end

  defp do_stream_ctrl(stream_ref, ctrl) do
    case ctrl do
      :play  -> StreamServer.play  stream_ref
      :pause -> StreamServer.pause stream_ref
      :next  -> StreamServer.next  stream_ref
      x -> Logger.warn "handle_playback_control : don't know how to handle #{inspect x}"
    end
  end
end
