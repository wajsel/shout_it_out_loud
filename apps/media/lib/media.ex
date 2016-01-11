defmodule Media do
  use Application

  #TODO: base_media_dir should be moved to shouter_app
  @base_media_dir "/Users/wiesel/sandbox/shouter_elixir/data/kiss"
  @ets_media_storage_name Media.Collection
  @stream_sup_name        Media.StreamSup
  @stream_server_name     Media.StreamServer
  @console_name           Media.Console

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    ets = :ets.new(@ets_media_storage_name,
                  [:set, :public, :named_table, {:read_concurrency, true}])
    children = [
      # Define workers and child supervisors to be supervised
      worker(Media.Collection,   [ets, [name: Media.Collection]]),
      supervisor(Media.StreamSup,[     [name: @stream_sup_name]]),
      worker(Media.StreamServer, [@stream_sup_name, [name: @stream_server_name]]),
      # ISSUE: console is a bit out of place in Media... (a new application?)
      worker(Media.Console,      [[name: @console_name]])
    ]
    opts = [strategy: :one_for_one, name: Media.Supervisor]
    res = Supervisor.start_link(children, opts)
    # Make sure we have mined a directory before other applications start
    #TODO shouter_app should be responsible for mining the directory when starting
    # and also make sure Media application is started
    Media.Collection.mine_dir(@base_media_dir, true)
    res
  end
end
# ============================================================================ #
defmodule Media.Collection do
  use GenServer
  require Logger

  def start_link(table, opt \\ [name: __MODULE__]) do
    Logger.info "start_link::table=#{inspect table}"
    GenServer.start_link(__MODULE__, {:ok, table}, opt)
  end

  def mine_dir(me \\ __MODULE__, dir, recursive) do
    Logger.debug "#{inspect me}, mine dir:#{inspect dir}"
    GenServer.call(me, {:mine, Path.absname(dir), recursive})
  end

  def list(me \\ __MODULE__) do
    Logger.debug "#{inspect me}, list"
    GenServer.call(me, :list)
  end

  # want to hide the ets table name and store it in state
  # otherwise we could have referenced it here globally in the api function
  def lookup(me \\ __MODULE__, ref) do
    Logger.debug "#{inspect me} lookup #{inspect ref}"
    GenServer.call(me, {:lookup, ref})
  end

  # ------------------------------------------------------------------------- #
  def init({:ok, table}) do
    Logger.info "init, table=#{inspect table}"
    {:ok, %{:table => table}}
  end

  def handle_call({:mine, dir, recursive}, _from, state) do
    # running this concurrent is unsafe as several read_mp3 would write to
    # the table from processes in parallel.
    Media.Mp3.find({:rec, recursive}, dir)
      |> Enum.map(&read_mp3(&1, state.table))
      #|> Enum.map(fn(f) -> spawn(fn -> read_mp3(f, state.table) end) end)
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    all = :ets.tab2list(state.table)
    Logger.debug "all #{inspect all}"
    {:reply, all, state}
  end

  #TODO: handle queries on id3 fields
  def handle_call({:lookup, ref}, _from, %{:table => table} = state) do
    {:reply, :ets.lookup(table, ref), state}
  end

  def handle_call(r, f, s) do
    Logger.warn "garbage request:#{inspect r} from:#{inspect f} state:#{inspect s}"
    {:noreply, s}
  end

  # ------------------------------------------------------------------------- #
  defp new_ref, do: :erlang.tuple_to_list :erlang.now()

  defp read_mp3(f_name, ets_table) do
    {:ok, id3} = Media.Mp3.id3(f_name)
    :ets.insert(ets_table, {new_ref(), %{:path => f_name, :id3 => id3}})
  end
end
# ============================================================================ #
defmodule Media.Mp3 do
  require Logger

  def id3(file_path_name) do
    case File.read(file_path_name) do
      {:ok, bin}   -> read_id3(bin)
      {:error, e}  -> {:error, {file_path_name, e}}
    end
  end

  def chunk_up(file_path_name, chunk_size) do
    case File.read(file_path_name) do
      {:ok, bin}  -> chunk_up_bin(chunk_size, bin, [])
      {:error, e} -> {:error, {file_path_name, e}}
    end
  end

  def get_bitrate(file_path_name) do
    cmd = "file " <> "\"" <> file_path_name <> "\""
    case get_bitrate_retries(cmd, 5) do
      {:ok, bitrate} -> bitrate
      :error         -> 0
    end
  end

  defp get_bitrate_retries(_cmd, 0), do: :error
  defp get_bitrate_retries(cmd, retries) do
    case Media.Console.execute(cmd) do
      {:data, str} ->
        Logger.info "#{inspect str}"
        b =
          String.split(str, ",", trim: true)
            |> Enum.filter(&String.contains?(&1, " kbps"))
            |> Enum.map(&String.split(&1, " ", trim: true))

        Logger.info "#{inspect b}"
        [[bitrate_str, "kbps"]] = b
        Logger.info "#{inspect bitrate_str}"
        Logger.info "#{inspect str}"
        {:ok, String.to_integer(bitrate_str)}
      {:error, _e} ->
        get_bitrate_retries(cmd, retries - 1)
    end
  end

  # could this be done with streams?
  # could this be more parallel?
  def find({:rec, true}, dir),  do: find_([dir], [])
  def find({:rec, false}, dir), do: find_(dir)

  defp find_([dir|dirs], mp3s),   do: find_(dirs ++ subdirs(dir),
                                            mp3s ++ find_(dir))
  defp find_([], mp3s), do: mp3s
  defp find_(dir),      do: files_with_ext(dir, [".mp3", ".MP3"])

  defp files_with_ext(dir, ext) do
    File.ls!(dir)
      |> Enum.filter(fn(f) -> String.ends_with?(f, ext) end )
      |> Enum.map(fn(f) -> Path.join(dir, f) end)
  end

  defp subdirs(dir) do
    File.ls!(dir)
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(fn(f) -> s = File.stat!(f)
                              s.type == :directory end)
  end

  # -------------------------------------------------------------------------- #
  defp read_id3 binary do
    byte_size = (byte_size(binary) - 128)
    << _ :: binary-size(byte_size), id3_tag :: binary >> = binary
    case id3_tag do
      << "TAG", title  :: binary-size(30),
                artist :: binary-size(30),
                album  :: binary-size(30),
                year   :: binary-size(4),
                comment:: binary-size(28),
                zero   :: binary-size(1),
                track  :: binary-size(1),
                genre  :: binary
      >> ->
        id3 = %{ :title => hd(String.split(title, <<0>>)),
                 :artist => hd(String.split(artist, <<0>>)),
                 :album => hd(String.split(album, <<0>>)),
                 :comment => comment,
                 :year => year,
                 :track => track,
                 :genre => genre }

        if zero == <<1>> do
          id3 = %{ id3 | :comment => String.split(comment <> zero <> track, <<0>>),
                         :track => <<0>> }
        else
          id3 = %{ id3 | :comment => hd(String.split(comment, <<0>>)) }
        end
        {:ok, id3}
      x ->
        {:error, x}
    end
  end

  defp chunk_up_bin(_size, <<>>, chunks), do: chunks
  defp chunk_up_bin(size, bin, chunks) when byte_size(bin) < size do
    pad_size = 8*(size - rem(byte_size(bin), size))
    chunks ++ [ bin <> <<0::size(pad_size)>> ]
  end
  defp chunk_up_bin(size, bin, chunks) do
    {chunk, rest} = :erlang.split_binary(bin, size)
    chunk_up_bin(size, rest, chunks ++ [chunk])
  end
end
# ============================================================================ #
defmodule Media.StreamSup do
  use Supervisor

  @ets_streamer_state_table Media.Streamer

  def start_link(opt \\ []) do
    Supervisor.start_link(__MODULE__, {:ok}, opt)
  end

  def start_stream(supervisor, ref) do
    Supervisor.start_child(supervisor, [ref, @ets_streamer_state_table])
  end

  # -------------------------------------------------------------------------- #
  def init({:ok}) do
    # ets table is created here but not used, its name is sent to new children
    _ets = :ets.new(@ets_streamer_state_table,
                  [:set, :public, :named_table ])
    children = [ worker(Media.Streamer, [], restart: :temporary) ]
    supervise(children, strategy: :simple_one_for_one)
  end
end
# ============================================================================ #
defmodule Media.StreamServer do
  use GenServer
  require Logger

  def start_link(supervisor, opt \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, {:ok, supervisor}, opt)
  end

  def create_stream(server \\ __MODULE__), do: GenServer.call(server, :create_stream)

  #TODO: should Ets be used for lookup?
  def lookup(server \\ __MODULE__, ref),   do: GenServer.call(server, {:lookup, ref})

  #TODO: should lookup_do be a macro?
  defp lookup_do(server, streamer, do_fun) do
    Logger.debug "lookup_do server=#{inspect server}, streamer=#{inspect streamer} do_fun=#{inspect do_fun}"
    case lookup(server, streamer) do
      {:ok, pid} -> do_fun.(pid)
      e ->
        Logger.warn "Error looking up reference #{inspect streamer} : #{inspect e}"
        e
    end
  end

  def stream_info(server \\ __MODULE__, stream), do:
    lookup_do(server, stream, fn p -> Media.Streamer.stream_info p end)

  def play(server \\ __MODULE__, stream), do:
    lookup_do(server, stream, fn p -> Media.Streamer.play p end)

  def pause(server \\ __MODULE__, stream), do:
    lookup_do(server, stream, fn p -> Media.Streamer.pause p end)

  def next(server \\ __MODULE__, stream), do:
    lookup_do(server, stream, fn p -> Media.Streamer.next p end)

  def add(server \\ __MODULE__, stream, media_ref) do
    lookup_do(server, stream, fn p -> Media.Streamer.add(p, media_ref) end)
  end
  def subscribe_to_shouts(server \\ __MODULE__, stream, subscriber, metadata), do:
    lookup_do(server, stream, fn p ->
              Media.Streamer.subscribe(p, subscriber, :time_to_shout, metadata) end)

  def subscribe_to_notices(server \\ __MODULE__, stream, subscriber), do:
    lookup_do(server, stream,
              fn p -> Media.Streamer.subscribe(p, subscriber, :notice) end)

  def listeners(server \\ __MODULE__, stream), do:
    lookup_do(server, stream, fn p -> Media.Streamer.listeners(p) end)

  def list(server \\ __MODULE__), do: GenServer.call(server, :list)
  def list_stream(server \\ __MODULE__, stream), do:
    lookup_do(server, stream, fn p -> Media.Streamer.list p end)

  def unsubscribe(server \\ __MODULE__, stream, subscriber), do:
    lookup_do(server, stream, fn p -> Media.Streamer.unsubscribe p, subscriber end)

  # -------------------------------------------------------------------------- #
  def init({:ok, supervisor}) do
    {:ok, %{:next_ref => 1,
            :sup => supervisor,
            :mon2ref => %{},
            :ref2pid => %{}}}
  end

  def handle_call(:list, _from, state) do
    {:reply, {:ok, Map.keys(state.ref2pid)}, state}
  end

  def handle_call(:create_stream, _from, state) do
    new_state = spawn_streamer(state.next_ref, state)
    {:reply, {:ok, state.next_ref}, %{new_state | :next_ref => state.next_ref + 1}}
  end

  def handle_call({:lookup, ref}, _from, state) do
    reply = case Map.get(state.ref2pid, ref) do
      nil -> {:error, {:ref_not_found, ref}}
      pid -> {:ok, pid}
    end
    {:reply, reply, state}
  end

  def handle_info({:DOWN, mon, :process, pid, :killed}, state) do
    Logger.info "noticed #{inspect pid} was killed"
    new_state = do_respawn(mon, pid, state)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, mon, :process, pid, :shutdown}, state) do
    Logger.info "noticed #{inspect pid} was shutdown"
    {ref, mon2ref}  = Map.pop(state.mon2ref, mon)
    {^pid, ref2pid} = Map.pop(state.ref2pid, ref)
    {:noreply, %{state | :ref2pid => ref2pid, :mon2ref => mon2ref}}
  end

  def handle_info({:DOWN, mon, :process, pid, reason}, state) do
    Logger.warn "noticed #{inspect pid} was #{inspect reason}"
    new_state = do_respawn(mon, pid, state)
    {:noreply, new_state}
  end
  # -------------------------------------------------------------------------- #

  defp do_respawn(mon, pid, state) do
    Logger.info "respawning #{inspect mon} #{inspect pid}"
    {ref, mon2ref}  = Map.pop(state.mon2ref, mon)
    {^pid, ref2pid} = Map.pop(state.ref2pid, ref)
    spawn_streamer(ref, %{state | :mon2ref => mon2ref, :ref2pid => ref2pid})
  end

  defp spawn_streamer(ref, state) do
    {:ok, pid} = Media.StreamSup.start_stream(state.sup, ref)
    mon = Process.monitor(pid)
    ref2pid = Map.put(state.ref2pid, ref, pid)
    mon2ref = Map.put(state.mon2ref, mon, ref)

    %{state | :ref2pid => ref2pid, :mon2ref => mon2ref}
  end
end
# ============================================================================ #
defmodule Media.Streamer do
  use GenServer
  require Logger

  @send_chunk_latency 10
  @chunk_size 65536
  @initial_shout_rate 1000 #initial too high value

  def start_link(ref, table, opts \\ []) do
    Logger.info "start_link : ref=#{inspect ref}, table=#{inspect table}"
    GenServer.start_link(__MODULE__, {:ok, ref, table}, opts)
  end

  def play(streamer),      do: GenServer.cast(streamer, :play)
  def pause(streamer),     do: GenServer.cast(streamer, :pause)
  def next(streamer),      do: GenServer.cast(streamer, :next)
  def list(streamer),      do: GenServer.call(streamer, :list)
  def add(streamer, media_ref), do: GenServer.call(streamer, {:add, media_ref})
  def listeners(streamer),      do: GenServer.call(streamer, :listeners)
  def stream_info(streamer),    do: GenServer.call(streamer, :stream_info)
  def subscribe(streamer, pid, type, metadata \\ []), do:
    GenServer.call(streamer, {:subscribe, pid, type, metadata})
  def unsubscribe(streamer, subscriber), do:
    GenServer.cast(streamer, {:unsubscribe, subscriber})

  # -------------------------------------------------------------------------- #
  def init({:ok, my_ref, table}) do
    Logger.info "init new Stream #{inspect self} with reference #{inspect my_ref} and table #{inspect table}"
    send(self, :initialize)
    {:ok, %{:my_ref => my_ref, #save ref to myself to be able to start from ets
            :table => table,
            :shout_subscribers => [],
            :notice_subscribers => [],
            :shouting => false,
            :playlist => [], # {song_ref, id3}
            :current_id3 => %{},
            :current_bitrate => 0,
            :chunks => [],
            :shout_rate => @initial_shout_rate}}
  end

  def handle_call(:debug, _from, state), do: {:reply, state, state}

  def handle_call(:stream_info, _from, state), do:
    {:reply, {:ok, {@chunk_size, state.current_bitrate, state.current_id3}}, state}

  def handle_call(:debug, _from, state), do: {:reply, state, state}

  def handle_call(:listeners, _from, %{:shout_subscribers => subs} = state), do:
    {:reply, subs, state}

  def handle_call({:subscribe, pid, :time_to_shout, metadata}, _from,
                  %{:shout_subscribers => subscribers} = state) do
    #TODO: monitor this pid and consider it an unsubscribe if it exits
    _mon = Process.monitor(pid)
    notice(state.notice_subscribers, {:new_listener, state.my_ref})
    new_state = save_state %{state | :shout_subscribers => subscribers ++ [{pid, metadata}]}
    {:reply, :ok, new_state}
  end

  def handle_call({:subscribe, pid, :notice, []}, _from,
                  %{:notice_subscribers => subscribers} = state) do
    _mon = Process.monitor(pid)
    new_state = save_state(%{state | :notice_subscribers => subscribers ++ [pid]})
    {:reply, :ok, new_state}
  end

  def handle_call({:add, ref}, _from, %{:playlist => playlist} = state) do
    [{^ref, data}] = Media.Collection.lookup(ref)
    new_state = save_state(%{state | :playlist => playlist ++ [{ref, data}]})
    {:reply, {:ok, {ref, data}}, new_state}
  end

  def handle_call(:list, _from, %{:playlist => playlist} = state), do:
    {:reply, playlist, state}

  def handle_call(data, from, state) do
    Logger.warn "garbage data=#{inspect data} from: #{inspect from} state= #{inspect state}"
    {:noreply, state}
  end


  def handle_cast({:unsubscribe, subscriber}, state) do
    shout_subs = state.shout_subscribers
                  |> Enum.filter(fn {p, _} -> p !== subscriber end)
    notice(state.notice_subscribers, {:removed_listener, state.my_ref})
    #shout_subs  = List.delete(state.shout_subscribers,  subscriber)
    notice_subs = List.delete(state.notice_subscribers, subscriber)
    new_state = save_state(%{state | :shout_subscribers => shout_subs,
                                     :notice_subscribers => notice_subs})

    Logger.info "subscribers after unsubscribe #{inspect shout_subs}, #{inspect notice_subs}"
    {:noreply, new_state}
  end

  def handle_cast(:play, %{:playlist => []} = state),  do: {:noreply, state}
  def handle_cast(:play, %{:shouting => true} = state), do: {:noreply, state}
  #TODO: make :play a call return false if nothing to play
  def handle_cast(:play, %{:chunks => [],
                           :playlist => [{ref, _data}|_rest]} = state) do
    {shout_rate, bitrate, id3, chunks} = process_ref(ref, @chunk_size)
    new_state = %{state | :chunks => chunks,
                          :shout_rate => shout_rate,
                          :current_id3 => id3,
                          :current_bitrate => bitrate}
    bump_shout 1
    {:noreply, save_state(new_state)}
  end

  def handle_cast(:play, state) do
    bump_shout 1
    notice state.notice_subscribers, {:started_shouting, state.my_ref}
    {:noreply, save_state( %{state | :shouting => true} )}
  end
  def handle_cast(:pause, state) do
    notice state.notice_subscribers, {:stoped_shouting, state.my_ref}
    {:noreply, save_state( %{state | :shouting => false} )}
  end
  def handle_cast(:next, state) do
    new_state = state |> advance_playlist |> save_state
    {:noreply, new_state}
  end
  def handle_info(:time_to_shout, %{:shout_subscribers => []} = state), do:
    {:noreply, %{state | :shouting => false}}

  def handle_info(:time_to_shout, %{:shouting => false}=state), do: {:noreply, state}
  def handle_info(:time_to_shout, %{:chunks => [],
                                    :playlist => []} = state) do
    notice(state.notice_subscribers, {:end_of_stream, state.my_ref})
    {:noreply, save_state( %{state | :shouting => false} )}
  end

  def handle_info(:time_to_shout, %{:chunks => []} = state) do
    bump_shout(state.shout_rate)
    new_state = state |> advance_playlist |> save_state
    {:noreply, new_state}
  end

  def handle_info(:time_to_shout, %{:chunks => [c|chunks]} = state) do
    shout(state.shout_subscribers, c)
    bump_shout(state.shout_rate)
    # TODO: should this be saved to state on every chunk, could every 10 or 100 chunk be ok?
    {:noreply, save_state(%{state | :chunks => chunks})}
  end

  def handle_info(:initialize, %{:table => table, :my_ref => my_ref} = state) do
    #read self from table if existing, otherwize store self
    new_state = case :ets.lookup(table, my_ref) do
      [] -> state
      [{^my_ref, stream_state}] -> stream_state
      x ->
        Logger.error "initialize, failed fetching state #{inspect x}"
        %{}
    end
    if new_state.shouting do
      bump_shout 1
    end
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _mon, :process, pid, reason}, state) do
    Logger.info "subscriber #{inspect pid} is DOWN for reason #{inspect reason}"
    GenServer.cast(self, {:unsubscribe, pid})
    {:noreply, state}
  end

  # -------------------------------------------------------------------------- #
  #TODO make bump_shout calculate time to next shout depending on time since last shout
  defp bump_shout(delay) do
    if delay > 0 do
      {:ok, _tref} = :timer.send_after(delay, :time_to_shout)
    else
      {:error, {:invalid_delay, delay}}
    end
  end

  defp shout(subscribers, chunk) do
    for {pid, _} <- subscribers, do:
      send(pid, {:time_to_shout, chunk})
  end

  defp notice(subscribers, n) do
    Logger.info "notice : subscribers = #{inspect subscribers}, notice=#{inspect n}"
    for pid <- subscribers do
      send(pid, {:stream_notify, n})
    end
  end

  defp advance_playlist(%{:playlist => []} = state), do: %{state | :chunks => []}
  defp advance_playlist(%{:playlist => [_x|rest] } = state) do
    {shout_rate, bitrate, id3, chunks} = case List.first(rest) do
      nil      -> {0, 0, %{}, []}
      {ref, _} -> process_ref(ref, @chunk_size)
    end
    notice(state.notice_subscribers, {:next_track, state.my_ref})
    %{state | :playlist    => rest,
              :current_id3 => id3,
              :current_bitrate => bitrate,
              :chunks      => chunks,
              :shout_rate  => shout_rate}
  end

  defp process_ref(song_ref, chunk_size) do
    [{^song_ref, %{:path => f_name}}] = Media.Collection.lookup(song_ref)
    case Media.Mp3.get_bitrate f_name do
      0       -> {0, 0, %{}, []}
      bitrate ->
        {:ok, id3} = Media.Mp3.id3(f_name)
        shout_rate = round(chunk_size * 8  / bitrate) - @send_chunk_latency
        if shout_rate > 0 do
          {shout_rate, round(bitrate), id3, Media.Mp3.chunk_up(f_name, chunk_size)}
        else
          {0, round(bitrate), id3, Media.Mp3.chunk_up(f_name, chunk_size)}
        end
    end
  end

  defp save_state state do
    :ets.insert(state.table, {state.my_ref, state})
    state
  end
end
# ============================================================================ #
defmodule Media.Console do
  use GenServer
  require Logger

  #ISSUE: could this be a task?
  # TODO: should there be a limit on number of processes running?
  def start_link(opts \\ []) do
    Logger.info "start_link opts = #{inspect opts}"
    GenServer.start_link(__MODULE__, {:ok}, opts)
  end

  def debug(me \\ __MODULE__), do:
    GenServer.cast(me, :debug)

  def execute(me \\ __MODULE__, cmd) do
    GenServer.call(me, {:cmd, cmd})
  end

  def init({:ok}) do
    { :ok, %{ :clients => %{}, :data => %{}} }
  end

  def handle_call({:cmd, cmd}, from, state) do
    port = Port.open({:spawn, cmd}, [:binary, :exit_status])
    clients = Map.put(state.clients, port, from)
    data    = Map.put(state.data, port, nil)
    new_state = %{state | :clients => clients, :data => data}
    {:noreply, new_state}
  end

  def handle_cast(:debug, state) do
    Logger.warn "unexpected #{inspect state}"
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, 0}}, state) when is_port(port) do
    client = Map.get(state.clients, port)
    data   = Map.get(state.data, port)
    GenServer.reply(client, data)
    {:noreply, cleanup(port, state)}
  end
  def handle_info({port, {:exit_status, es} = rc}, state) when is_port(port) do
    Logger.warn "port #{inspect port} exit with status: #{inspect es}, state:#{inspect state}"
    client = Map.get(state.clients, port)
    GenServer.reply(client, {:error, rc})
    {:noreply, cleanup(port, state)}
  end

  def handle_info({port, data}, state) when is_port(port) do
    data = Map.put(state.data, port, data)
    {:noreply, %{state | :data => data}}
  end

  defp cleanup(port, state) do
    clients = Map.delete(state.clients, port)
    data    = Map.delete(state.data, port)
    %{state | :clients => clients, :data => data}
  end
end
