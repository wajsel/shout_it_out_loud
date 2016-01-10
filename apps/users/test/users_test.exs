defmodule UsersTest.User do
  use ExUnit.Case
  alias Users.User

  @name_ref "user_name"

  test "can create a user with a name" do
    {:ok, user} = User.start_link(@name_ref)
    assert @name_ref == User.get_name(user)
  end


  test "validate init values of created user" do
    {:ok, user} = User.start_link @name_ref
    assert []  = User.get_playlists user
    assert nil = User.get_active_playlist user
  end


  test "can set active playlist" do
    {:ok, user} = User.start_link(@name_ref)
    assert nil == User.get_active_playlist(user)
    User.set_active_playlist(user, 2)
    assert 2 == User.get_active_playlist(user)
  end
end


defmodule UsersTest.UserServer do
  use ExUnit.Case
  alias Users.User
  alias Users.UserServer
  alias Users.UserSupervisor

  @name_ref "user_name"

  setup do
    {:ok, user_sup} = UserSupervisor.start_link
    {:ok, user_server} = UserServer.start_link user_sup, [name: Users.UserServer]
    {:ok, server: user_server}
  end

  test "can create a user", %{server: _user_server} do
    {:ok, pid} = UserServer.create(@name_ref)
    assert Process.alive?(pid)
  end

  test "can not create the same user twice" do
    {:ok, _pid} = UserServer.create(@name_ref)
    {:error, :name_in_use} = UserServer.create(@name_ref)
  end

  #test "a created user is listed as awake" do
  #  {:ok, pid} = UserServer.create(@name_ref)
  #  assert in_list?(UserServer.awake, @name_ref)
  #  assert not in_list?(UserServer.asleep, @name_ref)
  #end

  #test "can put a user to sleep" do
  #  {res, _pid} = UserServer.create(@name_ref)
  #  assert :ok == UserServer.sleep(@name_ref)
  #  assert in_list?(UserServer.asleep, @name_ref)
  #end


  #test "can not put a sleeping user to sleep" do
  #  {res, _pid} = UserServer.create(@name_ref)
  #  assert :ok == UserServer.sleep(@name_ref)
  #  assert {:error, :already_asleep} == UserServer.sleep(@name_ref)
  #end

  #test "can awake a sleeping user" do
  #  UserServer.create(@name_ref)
  #  assert :ok == UserServer.sleep(@name_ref)
  #  assert not in_list?(UserServer.awake, @name_ref)
  #  assert     in_list?(UserServer.asleep, @name_ref)
  #  assert :ok == UserServer.wake(@name_ref)
  #  assert     in_list?(UserServer.awake, @name_ref)
  #  assert not in_list?(UserServer.asleep, @name_ref)
  #end

  #test "can not wake an awake user" do
  #  UserServer.create(@name_ref)
  #  assert {:error, :already_awake} == UserServer.wake(@name_ref)
  #end

  test "a killed user is respawned" do
    {:ok, pid} = UserServer.create(@name_ref)
    assert Process.exit(pid, :kill)
    #TODO: remove sleep and implement GenEvent notifier to wait for signal on user exit
    :timer.sleep(100)
    assert not Process.alive?(pid)
    {:ok, respawned_pid} = UserServer.lookup(@name_ref)
    assert pid != respawned_pid
    assert Process.alive? respawned_pid
    assert User.get_name(respawned_pid) == @name_ref
  end

  test "a stopped (shutdown) user is not respawned" do
    {:ok, pid} = UserServer.create(@name_ref)
    assert Process.exit(pid, :shutdown)
    #TODO: remove sleep and implement GenEvent notifier to wait for signal on user exit
    :timer.sleep(100)
    assert not Process.alive?(pid)
    {:error, {:unmapped_name, @name_ref}} = UserServer.lookup(@name_ref)
  end

  #test "UserServer respawns awake users on startup" do
  #  {:ok, pid} = UserServer.create(@name_ref)
  #  {:ok, pid2} = UserServer.create("second_user")
  #  awake_pre = UserServer.awake
  #  Process.exit(UserServer, :shutdown)
  #  awake_post = UserServer.awake
  #  assert awake_pre == awake_post
  #end

  test "lookup pid is possible via name" do
    {:ok, pid} = UserServer.create(@name_ref)
    {:ok, looked_up_pid} = UserServer.lookup(@name_ref)
    assert pid == looked_up_pid
  end

  #test "lookup an asleep user gives :error" do
  #  {:ok, pid} = UserServer.create(@name_ref)
  #  assert {:ok, pid} == UserServer.lookup(@name_ref)
  #  :ok = UserServer.sleep(@name_ref)
  #  assert {:error, :user_asleep} == UserServer.lookup(@name_ref)
  #end

  test "lookup an unmapped name gives an error" do
    assert {:error, {:unmapped_name, @name_ref}} == UserServer.lookup(@name_ref)
  end

  test "active with active users is a list with user_names" do
    {:ok, pid} = UserServer.create(@name_ref)
    assert [@name_ref] == UserServer.get_active_user_names()
  end

  test "get active user names with no active users is an empty list" do
    assert [] == UserServer.get_active_user_names()
  end

  defp in_list?(lst, x) do
    x == Enum.find(lst, fn xx -> xx == x end)
  end
end
