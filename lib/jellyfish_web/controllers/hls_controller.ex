defmodule JellyfishWeb.HLSController do
  use JellyfishWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Jellyfish.Component.HLS.RequestHandler
  alias JellyfishWeb.ApiSpec
  alias JellyfishWeb.ApiSpec.HLS.{Params, Response}

  alias Plug.Conn

  action_fallback JellyfishWeb.FallbackController

  tags [:hls]

  operation :index,
    operation_id: "getHlsContent",
    summary: "Retrieve HLS Content",
    parameters: [
      room_id: [in: :path, description: "Room id", type: :string],
      filename: [in: :path, description: "Name of the file", type: :string],
      range: [in: :header, description: "Byte range of partial segment", type: :string],
      _HLS_msn: [in: :query, description: "Segment sequence number", type: Params.HlsMsn],
      _HLS_part: [
        in: :query,
        description: "Partial segment sequence number",
        type: Params.HlsPart
      ],
      _HLS_skip: [in: :query, description: "Is delta manifest requested", type: Params.HlsSkip]
    ],
    required: [:room_id, :filename],
    responses: [
      ok: ApiSpec.data("File was found", Response),
      not_found: ApiSpec.error("File not found"),
      bad_request: ApiSpec.error("Invalid filename")
    ]

  @playlist_content_type "application/vnd.apple.mpegurl"

  def index(
        conn,
        %{
          "_HLS_skip" => _skip
        } = params
      ) do
    params
    |> Map.update!("filename", &String.replace_suffix(&1, ".m3u8", "_delta.m3u8"))
    |> Map.delete("_HLS_skip")
    |> then(&index(conn, &1))
  end

  def index(
        conn,
        %{
          "room_id" => room_id,
          "filename" => filename,
          "_HLS_msn" => segment,
          "_HLS_part" => part
        }
      ) do
    partial = {String.to_integer(segment), String.to_integer(part)}

    result =
      if String.ends_with?(filename, "_delta.m3u8") do
        RequestHandler.handle_delta_manifest_request(room_id, partial)
      else
        RequestHandler.handle_manifest_request(room_id, partial)
      end

    case result do
      {:ok, manifest} ->
        conn
        |> put_resp_content_type(@playlist_content_type, nil)
        |> Conn.send_resp(200, manifest)

      {:error, reason} ->
        Logger.error("Error handling manifest request, reason: #{inspect(reason)}")
        {:error, :not_found, "File not found"}
    end
  end

  def index(conn, %{"room_id" => room_id, "filename" => filename}) do
    result =
      if String.ends_with?(filename, "_part.m4s") do
        RequestHandler.handle_partial_request(room_id, filename)
      else
        RequestHandler.handle_file_request(room_id, filename)
      end

    case result do
      {:ok, file} ->
        conn =
          if String.ends_with?(filename, ".m3u8"),
            do: put_resp_content_type(conn, @playlist_content_type, nil),
            else: conn

        Conn.send_resp(conn, 200, file)

      {:error, :invalid_path} ->
        {:error, :bad_request, "Invalid filename, got #{filename}"}

      {:error, _reason} ->
        {:error, :not_found, "File not found"}
    end
  end
end
