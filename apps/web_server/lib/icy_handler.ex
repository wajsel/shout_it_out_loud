defmodule IcyHandler do
  alias ShouterApp.ShouterIF
  require Logger

  @basedir "/Users/wiesel/sandbox/shouter_elixir"
  def init(_type, req, []) do
    Logger.info "me=#{inspect self}"
    Logger.debug "req=#{inspect req}"

    {stream_ref, req} = :cowboy_req.binding(:id, req, 0)
    stream_ref = String.to_integer(stream_ref)

    {headers, req} = :cowboy_req.headers(req)
    Logger.debug "headers #{inspect headers}"

    {user_agent, req} = :cowboy_req.header(<<"user-agent">>, req)
    Logger.debug "user_agent #{inspect user_agent}"

    {{ip, port}, req} = peer = :cowboy_req.peer(req)
    Logger.debug "peer #{inspect peer}"

    subscribe_meta = %{user_agent: user_agent,
                               ip: Tuple.to_list(ip),
                             port: port}
    case ShouterIF.handle({:streams, stream_ref, :subscribe_shouts, subscribe_meta}) do
      {_, :ok} ->
        {:ok, req} = :cowboy_req.chunked_reply(200, [], req)
        h = <<"HTTP/1.1 200 OK connection: keep-alive content-type: audio/mpeg">>
        :ok = :cowboy_req.chunk(h, req)

        Logger.info "Connection to stream #{inspect stream_ref} chunking away"
        {:loop, req, %{:stream_ref => stream_ref, :req => req}}
      {_, e} ->
        {:ok, req} = :cowboy_req.reply(204, [], req)
        Logger.error "Connection to stream #{inspect stream_ref} shutdown, error : #{inspect e}"
        {:shutdown, req, %{}}
    end
  end

  def info({:time_to_shout, chunk}, req, state) do
    #Logger.debug ":time_to_shout #{inspect chunk} while \n\treq=#{inspect req}\n\tstate=#{inspect state}"
    #ISSUE possible to get a race condition here if we try to reply with a chunk while
    # cowboy has closed connection and is about to send a terminated message to us

    case :cowboy_req.chunk(chunk, req) do
      :ok -> {:loop, req, state}
      _   -> {:shutdown, req, state}
    end
  end

  def info(data, req, state) do
    Logger.warn "unexpected info: #{inspect data} while \n\treq=#{inspect req},\n\tstate=#{inspect state}"
    {:loop, req, state}
  end

  # Required callback.  Put any essential clean-up here.
  def terminate(reason, req, state) do
    Logger.warn "terminating for reason #{inspect reason}"
    Logger.debug "req=#{inspect req}\nstate=#{inspect state}"
    :ok
  end

end
