Mix.install([
  # Keep in mind that you should lock onto a specific version of Jellyfish
  # and the Jellyfish Server SDK in production code
  {:jellyfish_server_sdk, github: "jellyfish-dev/elixir_server_sdk"}
])

defmodule SendFileToRoom do
  require Logger

  @jellyfish_hostname "localhost"
  @jellyfish_port 5002
  @jellyfish_token "development"

  def run(room_id, load_file_from_path) do
    client =
      Jellyfish.Client.new(
        server_address: "#{@jellyfish_hostname}:#{@jellyfish_port}",
        server_api_token: @jellyfish_token
      )

    with {:ok, %Jellyfish.Room{id: room_id}} <-
           Jellyfish.Room.get(client, room_id),
         {:ok, %Jellyfish.Component{id: _file_component}} <-
           Jellyfish.Room.add_component(client, room_id, %Jellyfish.Component.File{
             file_path: load_file_from_path
           }) do
      Logger.info("Components added successfully")
    else
      {:error, reason} ->
        Logger.error("""
        Error when attempting to communicate with Jellyfish: #{inspect(reason)}
        Make sure you have started it by running `mix phx.server`
        """)
    end
  end
end

case System.argv() do
  [room_id | rest] ->
    case rest do
      [load_file_from_path | _rest] ->
        SendFileToRoom.run(room_id, load_file_from_path)

      _empty ->
        raise(
          "No output path specified, make sure you pass it as the argument to this script. For example `elixir examples/send_file_to_room.exs \"room_id\" \"testing\"`"
        )
    end

  _empty ->
    raise(
      "No room ID specified, make sure you pass it as the argument to this script. For example `elixir examples/send_file_to_room.exs \"room_id\" \"testing\"`"
    )
end
