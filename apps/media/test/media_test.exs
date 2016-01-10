defmodule MediaTest.Collection do
  # is it ok to run async when using :ets ?
  use ExUnit.Case, async: true

  alias Media.Collection

  @basedir "/Users/wiesel/sandbox/shouter_elixir"

  setup do
    ets = :ets.new(:test_ets,
                   [:set, :public, :named_table,
                     {:read_concurrency, true}, {:write_concurrency, false}])
    {:ok, collection} = Collection.start_link(ets, [name: Media.Collection])
    {:ok, collection: collection}
  end

  test "mining directory nonrec finds no files of type .mp3", %{collection: c} do
    :ok = Collection.mine_dir(c, @basedir, false)
    lst = Collection.list(c)
    assert [] == lst
  end

  test "list whats in collection", %{collection: c} do
    :ok = Collection.mine_dir(c, @basedir, true)
    lst = Collection.list(c)
    assert [] != lst
  end

  test "lookup by reference return reference and data as a list", %{collection: c} do
    :ok = Collection.mine_dir(c, @basedir, true)
    lst = Collection.list(c)
    {ref, data} = hd lst
    assert [{ref, data}] == Collection.lookup(c, ref)
  end

  test "lookup by unknown reference return an empty list", %{collection: c} do
    :ok = Collection.mine_dir(c, @basedir, true)
    new_ref = make_ref
    assert [] == Collection.lookup(c, new_ref)
  end
end

defmodule MediaTest.Mp3 do
  use ExUnit.Case, async: true

  alias Media.Mp3

  @test_mp3_file "/Users/wiesel/sandbox/shouter_elixir/Data/Buena Vista Social Club/Amor De Loca Juventud.mp3"

  test "Can read id3 tag from valid file (#{inspect @test_mp3_file})" do
    {:ok, id3} = Mp3.id3(@test_mp3_file)
    %{:title => title,
      :artist => artist,
      :album => album,
      :year => year,
      :track => track,
      :comment => comment} = id3

    assert title  == "Amor De Loca Juventud"
    assert artist == "Buena Vista Social Club"
    assert album  == "Buena Vista Social Club"
    assert year   == "1997"
    assert track  == <<10>>
    assert comment  == ""
  end

  test "Read id3 from nonexisting file returns an error and filepathname" do
    # at the moment we don't care about the error type
    # forwarding File.open error or an internal error
    dummy_filename = "./nonexeisting/path/nofile"
    {:error, {filepathname, _}} = Mp3.id3(dummy_filename)
    assert dummy_filename == filepathname
  end
end

defmodule MediaTest.Streamer do
  use ExUnit.Case#, async: true

  alias Media.StreamSup
  alias Media.Streamer
  alias Media.StreamServer
  alias Media.Collection

  @basedir "/Users/wiesel/sandbox/shouter_elixir"

  setup do
    ets = :ets.new(:test_ets_streamer,
                   [:set, :public, :named_table,
                    {:read_concurrency, true}, {:write_concurrency, false}])

    {:ok, collection} = Collection.start_link(ets)
    {:ok, stream_sup} = StreamSup.start_link()
    {:ok, stream_server} = StreamServer.start_link(stream_sup)
    {:ok, collection: collection,
          stream_sup: stream_sup,
          stream_server: stream_server}
  end

  test "MediaTest.Streamer test", %{collection: collection,
                                    stream_server: s_server,
                                    stream_sup: _s_sup } = cc do
    :ok = Collection.mine_dir(collection, @basedir, true)
    mp3 = hd Collection.list(collection)
    {mp3_ref, data} = mp3
    #IO.puts("first file:#{inspect mp3}")

    {:ok, stream_ref} = StreamServer.create_stream
    x = StreamServer.add(stream_ref, mp3_ref)
    #IO.puts("x:#{inspect x}")
    IO.puts("subscribe")
    StreamServer.subscribe(stream_ref)
    IO.puts("play")
    StreamServer.play(stream_ref)
    x = receive do
      xx -> xx
    after 1000 -> "nothing"
    end
    IO.puts("x:#{inspect x}")
    IO.puts("pause")
    StreamServer.pause(stream_ref)
    :timer.sleep(1000)

  end

  test "Add media to Media.Streamer", %{collection: collection,
                                        stream_server: s_server,
                                        stream_sup: _s_sup} = cc do
    :ok = Collection.mine_dir(collection, @basedir, true)
    {media_ref, media_data} = hd Collection.list(collection)
    {:ok, stream_ref} = StreamServer.create_stream
    x = StreamServer.add(stream_ref, media_ref)
    IO.puts("x:#{inspect x}")
    #playlist = StreamServer.list stream_ref
    {:ok, streamer_pid} = StreamServer.lookup(stream_ref)
    playlist = Streamer.list(streamer_pid)
    IO.puts("playlist:#{inspect playlist}")
    assert playlist != []
  end

  test "Add media to Media.Streamer via Media.StreamServer",
                                      %{collection: collection,
                                        stream_server: s_server,
                                        stream_sup: _s_sup} = cc do
    :ok = Collection.mine_dir(collection, @basedir, true)
    {media_ref, media_data} = hd Collection.list(collection)
    {:ok, stream_ref} = StreamServer.create_stream
    x = StreamServer.add(stream_ref, media_ref)
    IO.puts("x:#{inspect x}")
    playlist = StreamServer.list_stream stream_ref
    IO.puts("playlist:#{inspect playlist}")
    assert playlist != []
  end
end
