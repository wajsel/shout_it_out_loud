defmodule WebsocketHandler do
  @behaviour :cowboy_websocket_handler
  require Pipe
  require Logger
  alias ShouterApp.ShouterIF

  def init({_tcp, _http}, _req, _opts) do
    Logger.info "init: you've been upgraded"
    {:upgrade, :protocol, :cowboy_websocket}
  end

  def websocket_init(_TransportName, req, _opts) do
    Logger.info "init: you've been upgraded"
    {:ok, req, %{:user => nil} }
  end

  # Required callback.  Put any essential clean-up here.
  def websocket_terminate(reason, _req, _state) do
    Logger.info "websocket_terminate for reason:#{inspect reason}"
    :ok
  end

  # websocket_handle deals with messages coming in over the websocket.
  # it should return a 4-tuple starting with either :ok (to do nothing)
  # or :reply (to send a message back).
  def websocket_handle({:text, content}, req, state) do
    Logger.info "incoming:#{inspect content}"

    response = Pipe.pipe_matching x, {:ok, x},
      JSX.decode(content)
        |> toShouterCommand
        |> ShouterIF.handle
        |> transformResponse
    reply(response, req, state)
  end
  def websocket_handle(data, req, state) do
    # fallback message handler
    Logger.warn "unexpected #{inspect data}"
    {:ok, req, state}
  end

  def websocket_info({:stream_notify, n} = notice, req, state) do
    Logger.info "notice from stream: #{inspect notice}"
    response = Pipe.pipe_matching x, {:ok, x},
      actOnStreamNotice(n)
        |> ShouterIF.handle
        |> transformResponse
    reply(response, req, state)
  end
  def websocket_info({:users_notify, n}=notice, req, state) do
    Logger.info "notice from user: #{inspect notice}"
    response = Pipe.pipe_matching x, {:ok, x},
      actOnUserNotice(n)
        |> ShouterIF.handle
        |> transformResponse
    reply(response, req, state)
  end
  def websocket_info(info, req, state) do
    # fallback message handler
    Logger.warn "unexpected info=#{inspect info}"
    {:ok, req, state}
  end

  #---------------------------------------------------------------------#
  defp actOnUserNotice({:new_user, _user}) do
    {:ok, {:users, :list}}
  end
  defp actOnUserNotice(unexpected) do
    {:nok, {:actOnUserNotice_unexpected, unexpected}}
  end

  defp actOnStreamNotice({n, id}) when n in [:new_listener, :removed_listener] do
    {:ok, {:streams, id, :list_stream_listeners}}
  end
  defp actOnStreamNotice({n, id}) when n in [:next_track, :end_of_stream] do
    {:ok, {:streams, id, :list}}
  end
  defp actOnStreamNotice(unexpected) do
    {:nok, {:actOnStreamNotice_unexpected, unexpected}}
  end

  defp reply(:ok, req, state) do
    {:ok, req, state}
  end
  defp reply({:ok, reply}, req, state) do
    case JSX.encode reply do
      {:ok, r} ->
        {:reply, {:text, r}, req, state}
      x ->
        Logger.error "encoding error #{inspect reply} :: #{inspect x}"
        {:ok, req, state}
    end
  end
  defp reply(x, req, state) do
    Logger.error "reply error #{inspect x}"
    {:ok, req, state}
  end

  defp toShouterCommand(%{"ws_ctrl" => ctrl, "stream" => stream_id})
                        when ctrl in ["play", "pause", "next"] do
    {:ok, {:stream, stream_id, String.to_atom(ctrl)}}
  end

  defp toShouterCommand(%{"ws_ctrl" => ctrl, "user" => user})
                        when ctrl in ["play", "pause", "next"] do
    {:ok, {:users, user, :playback, String.to_atom(ctrl)}}
  end

  defp toShouterCommand(%{"user" => user, "stream" => %{"add" => id}}), do:
    {:ok, {:users, user, :add_media_to_stream, id}}

  defp toShouterCommand( %{"login" => user} ),     do: {:ok, {:users, user,
                                                              :login,
                                                              :subscribe_notices}}
  defp toShouterCommand(%{"user" => user,
                          "devices" => "get"}),    do: {:ok, {:users, user,
                                                              :list_stream_listeners}}
  defp toShouterCommand(%{"user" => user,
                          "stream" => "get"}),     do: {:ok, {:users, user,
                                                              :list_stream}}
  defp toShouterCommand(%{"collection" => "get"}), do: {:ok, {:collection, :list}}
  defp toShouterCommand(%{"users" => "get"}),      do: {:ok, {:users, :list}}
  defp toShouterCommand(x),                        do: {:nok,{:unknown, x}}

  defp transformResponse(%{:stream => stream_content}) do
    media = Enum.map(stream_content,
                     fn {ref, data} -> %{:ref => ref, :data => data} end)
    {:ok, %{:stream => media}}
  end
  defp transformResponse(%{:collection => collection}) do
    media = Enum.map(collection,
                     fn {ref, data} -> %{:ref => ref, :data => data} end)
    {:ok, %{:collection => media}}
  end
  defp transformResponse({:ok, data}) do
    transformResponse data
  end
  defp transformResponse(:ok),              do: :ok
  defp transformResponse(m) when is_map(m), do: {:ok, m}
  defp transformResponse(x),                do: {:nok, {:unknown, x}}
end
