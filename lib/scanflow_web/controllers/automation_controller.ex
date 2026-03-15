defmodule ScanflowWeb.AutomationController do
  use ScanflowWeb, :controller
  require Logger

  alias Scanflow.Automation.Config

  def scan(conn, params) do
    button = params["button"]
    session_key = "default"
    finalize_button_single = Config.finalize_handler()
    finalize_button_double = Config.finalize_double_handler()

    if is_binary(button) and String.trim(button) != "" do
      Logger.info("HA scan event received button=#{button} session_key=#{session_key}")

      result =
        cond do
          button == finalize_button_single ->
            Logger.info("Button #{button} mapped to finalize flow (send email)")
            Scanflow.Automation.SessionManager.finalize(button, session_key, send_email: true)

          button == finalize_button_double ->
            Logger.info("Button #{button} mapped to finalize flow (no email)")
            Scanflow.Automation.SessionManager.finalize(button, session_key, send_email: false)

          true ->
            Scanflow.Automation.SessionManager.scan_page(button, session_key)
        end

      case result do
        {:ok, payload} ->
          Logger.info("HA scan event processed button=#{button} result=#{inspect(payload)}")
          json(conn, payload)

        {:error, error} ->
          Logger.error("HA scan event failed button=#{button} error=#{inspect(error)}")
          conn |> put_status(422) |> json(%{error: error})
      end
    else
      conn |> put_status(400) |> json(%{error: "button is required"})
    end
  end

  def paperless_webhook(conn, params) do
    Logger.info(
      "Paperless webhook raw conn.params: #{inspect(conn.params, pretty: true, limit: :infinity)}"
    )

    Logger.info(
      "Paperless webhook raw body_params: #{inspect(conn.body_params, pretty: true, limit: :infinity)}"
    )

    Logger.info(
      "Paperless webhook raw query_params: #{inspect(conn.query_params, pretty: true, limit: :infinity)}"
    )

    Logger.info(
      "Paperless webhook raw controller params: #{inspect(params, pretty: true, limit: :infinity)}"
    )

    document_id = extract_document_id(params)

    Logger.info("Paperless webhook extracted document_id=#{inspect(document_id)}")

    case parse_int(document_id) do
      {:ok, doc_id} ->
        _ =
          Task.Supervisor.start_child(Scanflow.AutomationTaskSupervisor, fn ->
            Scanflow.Automation.Processor.process_webhook_document(doc_id)
          end)

        conn |> put_status(202) |> json(%{status: "accepted", document_id: doc_id})

      :error ->
        Logger.error(
          "Paperless webhook could not extract document_id from params=#{inspect(params, pretty: true, limit: :infinity)}"
        )

        conn |> put_status(400) |> json(%{error: "document_id is required"})
    end
  end

  defp extract_document_id(params) when is_map(params) do
    params["document_id"] || params["id"] || get_in(params, ["document", "id"]) ||
      get_in(params, ["data", "id"]) || params["url"] ||
      extract_document_id_from_json_blob(params["_json"])
  end

  defp extract_document_id(_), do: nil

  defp extract_document_id_from_json_blob(nil), do: nil

  defp extract_document_id_from_json_blob(raw) when is_map(raw) do
    raw["document_id"] || raw["id"] || raw["url"]
  end

  defp extract_document_id_from_json_blob(raw) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(raw),
         doc_or_url <- decoded["document_id"] || decoded["id"] || decoded["url"] do
      doc_or_url
    else
      _ -> nil
    end
  end

  defp extract_document_id_from_json_blob(_), do: nil

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        :error

      Regex.match?(~r/^\d+$/, value) ->
        {:ok, String.to_integer(value)}

      true ->
        case Regex.run(~r{/documents/(\d+)/?}, value, capture: :all_but_first) do
          [id] -> {:ok, String.to_integer(id)}
          _ -> :error
        end
    end
  end

  defp parse_int(_), do: :error
end
