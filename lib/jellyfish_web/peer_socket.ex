defmodule JellyfishWeb.PeerSocket do
  @moduledoc false
  @behaviour Phoenix.Socket.Transport
  require Logger

  alias Jellyfish.Event
  alias Jellyfish.PeerMessage
  alias Jellyfish.PeerMessage.{Authenticated, AuthRequest, MediaEvent}
  alias Jellyfish.{Room, RoomService}
  alias JellyfishWeb.PeerToken

  @heartbeat_interval 30_000

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(state) do
    Logger.info("New incoming peer WebSocket connection, accepting")
    IO.inspect(state)
    # Make sure the return format is either "binary" or "text"

    return_format =
      with return_format <- state.params |> Map.get("return_format", "binary") do
        case return_format do
          "binary" -> :binary
          "text" -> :text
          _ -> :binary
        end
      end

    {:ok, state |> Map.put(:return_format, return_format)}
  end

  @impl true
  def init(state) do
    {:ok, Map.put(state, :authenticated?, false)}
  end

  @impl true
  def handle_in({encoded_message, [opcode: :binary]}, %{authenticated?: false} = state) do
    case PeerMessage.decode(encoded_message) do
      %PeerMessage{content: {:auth_request, %AuthRequest{token: token}}} ->
        with {:ok, %{peer_id: peer_id, room_id: room_id}} <- PeerToken.verify(token),
             {:ok, room_pid} <- RoomService.find_room(room_id),
             :ok <- Room.set_peer_connected(room_id, peer_id),
             :ok <- Phoenix.PubSub.subscribe(Jellyfish.PubSub, room_id) do
          Process.send_after(self(), :send_ping, @heartbeat_interval)

          response_message = %PeerMessage{content: {:authenticated, %Authenticated{}}}
          encoded_message = PeerMessage.encode(response_message)

          state =
            state
            |> Map.merge(%{
              authenticated?: true,
              peer_id: peer_id,
              room_id: room_id,
              room_pid: room_pid
            })

          Event.broadcast_server_notification({:peer_connected, room_id, peer_id})

          if state.return_format == :text do
            # Just send the response message as is, without protobuf encoding
            # This is to support Unity right now.
            response_map = Jellyfish.PeerMessage.to_map(response_message)
            json_response = Jason.encode!(response_map)
            {:reply, :ok, {:text, json_response}, state}
          else
            {:reply, :ok, {:binary, encoded_message}, state}
          end
        else
          {:error, reason} ->
            reason = reason_to_string(reason)

            Logger.warning("""
            Authentication failed, reason: #{reason}.
            Closing the connection.
            """)

            {:stop, :closed, {1000, reason}, state}
        end

      _other ->
        Logger.warning("""
        Received message from unauthenticated peer that is not authRequest.
        Closing the connection.
        """)

        {:stop, :closed, {1000, "unauthenticated"}, state}
    end
  end

  @impl true
  def handle_in({encoded_message, [opcode: :binary]}, state) do
    case PeerMessage.decode(encoded_message) do
      %PeerMessage{content: {:media_event, %MediaEvent{data: data}}} ->
        Room.receive_media_event(state.room_id, state.peer_id, data)

      other ->
        Logger.warning("""
        Received unexpected message #{inspect(other)} from #{inspect(state.peer_id)}, \
        room: #{inspect(state.room_id)}
        """)
    end

    {:ok, state}
  end

  @impl true
  def handle_in({msg, [opcode: :text]}, state) do
    Logger.warning("""
    Received unexpected text message #{msg} from #{inspect(state.peer_id)}, \
    room: #{inspect(state.room_id)}
    """)

    {:ok, state}
  end

  @impl true
  def handle_info({:media_event, data}, state) when is_binary(data) do
    peer_message = %PeerMessage{content: {:media_event, %MediaEvent{data: data}}}
    encoded_message = PeerMessage.encode(peer_message)

    IO.puts("Sending back:")
    IO.inspect(peer_message)
    IO.inspect(encoded_message)
    IO.inspect(encoded_message |> byte_size())
    IO.puts("Returning format: #{state.return_format}")

    # {:push, {:binary, encoded_message}, state}

    if state.return_format == :text do
      # Just send the response message as is, without protobuf encoding
      # This is to support Unity right now.
      response_map = Jellyfish.PeerMessage.to_map(peer_message)
      json_response = Jason.encode!(response_map)
      {:push, {:text, json_response}, state}
    else
      {:push, {:binary, encoded_message}, state}
    end
  end

  @impl true
  def handle_info(:send_ping, state) do
    Process.send_after(self(), :send_ping, @heartbeat_interval)
    {:push, {:ping, ""}, state}
  end

  @impl true
  def handle_info({:stop_connection, :peer_removed}, state) do
    {:stop, :closed, {1000, "Peer removed"}, state}
  end

  @impl true
  def handle_info({:stop_connection, :room_stopped}, state) do
    {:stop, :closed, {1000, "Room stopped"}, state}
  end

  @impl true
  def handle_info({:stop_connection, _reason}, state) do
    {:stop, :closed, {1011, "Internal server error"}, state}
  end

  @impl true
  def handle_info(:room_crashed, state) do
    {:stop, :closed, {1011, "Internal server error"}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  defp reason_to_string(:invalid), do: "invalid token"
  defp reason_to_string(:missing), do: "missing token"
  defp reason_to_string(:expired), do: "expired token"
  defp reason_to_string(:room_not_found), do: "room not found"
  defp reason_to_string(:peer_not_found), do: "peer not found"
  defp reason_to_string(:peer_already_connected), do: "peer already connected"
  defp reason_to_string(other), do: "#{other}"
end
