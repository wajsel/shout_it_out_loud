defmodule Users.User do

  def start_link(state), do: Agent.start_link(fn -> state end)
  def start_link(name, stream_ref) do
    Agent.start_link(fn -> %{:name => name,
                             :stream_ref => stream_ref}
                     end)
  end

  def get_stream_ref(user), do: Agent.get(user, &Map.get(&1, :stream_ref))
  def get_name(user),       do: Agent.get(user, &Map.get(&1, :name))
  def get(user),            do: Agent.get(user, fn x -> x end)
end
