defmodule WebServer do
  use Application

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    #TODO: separate the webserver and the supervisor.
    # Put the webserver in a genserver as a WebServer.Worker
    # ¿ perhaps the IcyHandler be put in its own server?
    # and on startup deployed on different node, I.e. load balancing
    import Supervisor.Spec, warn: false

    dispatch = :cowboy_router.compile([
      { :_,
        [ {"/", :cowboy_static, {:priv_file, :web_server, "index.html"}},
          {"/static/[...]", :cowboy_static, {:priv_dir, :web_server, "static_files"}},
          {"/shout/:id", IcyHandler, []},
          {"/websocket", WebsocketHandler, []}
        ]}
      ])
    #TODO: fetch port and number of connecton handlers from environment
    {:ok, _} = :cowboy.start_http(:http,
                                  100,
                                  [{:port, 2050}],
                                  [{:env, [{:dispatch, dispatch}]}])
    children = [
      # Define workers and child supervisors to be supervised
      # worker(WebServer.Worker, [arg1, arg2, arg3])
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WebServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
