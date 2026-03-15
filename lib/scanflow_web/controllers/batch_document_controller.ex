defmodule ScanflowWeb.BatchDocumentController do
  use ScanflowWeb, :controller

  def thumb(conn, %{"id" => id}) do
    doc_id = String.to_integer(id)

    case Scanflow.Api.download_document_thumbnail(doc_id) do
      {:ok, %{body: body, content_type: content_type}} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_resp(200, body)

      {:error, error} ->
        conn
        |> put_status(502)
        |> text(error)
    end
  end

  def source(conn, %{"id" => id}) do
    doc_id = String.to_integer(id)

    case Scanflow.Api.download_document_binary(doc_id) do
      {:ok, %{body: body, content_type: content_type, content_disposition: disposition}} ->
        inline_disposition =
          case disposition do
            nil -> "inline"
            value -> Regex.replace(~r/^attachment/i, value, "inline")
          end

        conn =
          conn
          |> put_resp_content_type(content_type)
          |> put_resp_header("content-disposition", inline_disposition)

        send_resp(conn, 200, body)

      {:error, error} ->
        conn
        |> put_status(502)
        |> text(error)
    end
  end
end
