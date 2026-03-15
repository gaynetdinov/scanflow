defmodule ScanflowWeb.BatchDocumentLive.Show do
  use ScanflowWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Scanflow.Batch.subscribe()

    {:ok,
     assign(socket,
       doc_id: nil,
       doc: nil,
       tags: %{},
       paperless_doc_url: nil,
       loading: true,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    doc_id = String.to_integer(id)

    paperless_url =
      Application.get_env(:scanflow, :paperless_api, [])
      |> Keyword.get(:endpoint, "")
      |> String.trim_trailing("/")
      |> then(fn endpoint ->
        if endpoint == "", do: nil, else: "#{endpoint}/documents/#{doc_id}/details"
      end)

    tags =
      case Scanflow.Api.fetch_tags() do
        {:ok, loaded_tags} -> loaded_tags
        _ -> %{}
      end

    doc = Scanflow.Batch.get_document(doc_id)

    socket =
      assign(socket,
        doc_id: doc_id,
        doc: doc,
        tags: tags,
        paperless_doc_url: paperless_url,
        loading: false,
        error: if(is_nil(doc), do: "Batch state not found for this document", else: nil)
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_doc_ocr_text", %{"ocr_text" => value}, socket) do
    with %{doc: %{id: id}} <- socket.assigns do
      _ = Scanflow.Batch.update_document(id, fn current -> %{current | ocr_text: value} end)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_suggested_title", %{"suggested_title" => value}, socket) do
    with %{doc: %{id: id}} <- socket.assigns do
      _ =
        Scanflow.Batch.update_document(id, fn current ->
          %{current | suggested_title: value}
        end)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_apply_suggestion", %{"field" => field}, socket) do
    with %{doc: %{id: id}} <- socket.assigns do
      key = String.to_atom("apply_#{field}_suggestion")

      _ =
        Scanflow.Batch.update_document(id, fn current ->
          Map.put(current, key, !Map.get(current, key, true))
        end)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_suggested_tag", %{"tag_name" => tag_name}, socket) do
    normalized = String.trim(tag_name)

    with %{doc: %{id: id}} <- socket.assigns,
         true <- normalized != "" do
      _ =
        Scanflow.Batch.update_document(id, fn current ->
          tags = current.suggested_tags || []

          if normalized in tags,
            do: current,
            else: %{current | suggested_tags: tags ++ [normalized]}
        end)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_suggested_tag", %{"tag_name" => tag_name}, socket) do
    with %{doc: %{id: id}} <- socket.assigns do
      _ =
        Scanflow.Batch.update_document(id, fn current ->
          %{current | suggested_tags: List.delete(current.suggested_tags || [], tag_name)}
        end)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("apply_doc_suggestions", _params, socket) do
    with %{doc: %{id: id}} <- socket.assigns do
      _ = Scanflow.Batch.apply_suggestions(id)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:document_updated, updated_doc}, socket) do
    if socket.assigns.doc_id == updated_doc.id do
      {:noreply, assign(socket, doc: updated_doc, error: nil)}
    else
      {:noreply, socket}
    end
  end
end
