defmodule ScanflowWeb.BatchLive do
  use ScanflowWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Scanflow.Batch.subscribe()

    batch_documents = Scanflow.Batch.list_documents()

    socket =
      assign(socket,
        documents: [],
        tags: %{},
        paperless_api_endpoint:
          Application.get_env(:scanflow, :paperless_api, [])
          |> Keyword.get(:endpoint, "")
          |> String.trim_trailing("/"),
        selected_ids: MapSet.new(),
        page: 1,
        page_size: 25,
        total_count: 0,
        next_page: nil,
        previous_page: nil,
        search_query: "",
        loading: true,
        error: nil,
        batch_by_id: Map.new(batch_documents, &{&1.id, &1}),
        mounted: false
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    query = params["q"] || ""

    if !socket.assigns.mounted || socket.assigns.page != page ||
         socket.assigns.search_query != query do
      socket =
        socket
        |> assign(page: page, search_query: query, mounted: true)
        |> load_documents()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    doc_id = String.to_integer(id)

    selected_ids =
      if MapSet.member?(socket.assigns.selected_ids, doc_id) do
        MapSet.delete(socket.assigns.selected_ids, doc_id)
      else
        MapSet.put(socket.assigns.selected_ids, doc_id)
      end

    {:noreply, assign(socket, selected_ids: selected_ids)}
  end

  @impl true
  def handle_event("enqueue_selected", _params, socket) do
    selected_docs =
      socket.assigns.documents
      |> Enum.filter(fn doc -> MapSet.member?(socket.assigns.selected_ids, doc.id) end)

    if selected_docs != [] do
      _ = Scanflow.Batch.enqueue_documents(selected_docs)
    end

    {:noreply,
     socket
     |> assign(selected_ids: MapSet.new())}
  end

  @impl true
  def handle_event("apply_doc_suggestions", %{"id" => id}, socket) do
    doc_id = String.to_integer(id)
    _ = Scanflow.Batch.apply_suggestions(doc_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_doc_ocr_text", %{"doc_id" => id} = params, socket) do
    doc_id = String.to_integer(id)
    ocr_text = Map.get(params, "ocr_text") || Map.get(params, "ocr_text_#{doc_id}") || ""

    _ =
      Scanflow.Batch.update_document(doc_id, fn current ->
        %{current | ocr_text: ocr_text, status_detail: "OCR text edited"}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "update_suggested_title",
        %{"doc_id" => id, "suggested_title" => title},
        socket
      ) do
    doc_id = String.to_integer(id)

    _ =
      Scanflow.Batch.update_document(doc_id, fn current ->
        %{current | suggested_title: title, status_detail: "Suggested title edited"}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_suggested_tag", %{"doc_id" => id, "tag_name" => tag_name}, socket) do
    doc_id = String.to_integer(id)
    normalized = String.trim(tag_name)

    if normalized != "" do
      _ =
        Scanflow.Batch.update_document(doc_id, fn current ->
          tags = current.suggested_tags || []

          if normalized in tags do
            current
          else
            %{
              current
              | suggested_tags: tags ++ [normalized],
                status_detail: "Suggested tags edited"
            }
          end
        end)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_suggested_tag", %{"doc_id" => id, "tag_name" => tag_name}, socket) do
    doc_id = String.to_integer(id)

    _ =
      Scanflow.Batch.update_document(doc_id, fn current ->
        %{
          current
          | suggested_tags: List.delete(current.suggested_tags || [], tag_name),
            status_detail: "Suggested tags edited"
        }
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_apply_suggestion", %{"doc_id" => id, "field" => field}, socket) do
    doc_id = String.to_integer(id)
    key = String.to_atom("apply_#{field}_suggestion")

    _ =
      Scanflow.Batch.update_document(doc_id, fn current ->
        current_value = Map.get(current, key, true)
        Map.put(current, key, !current_value)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("pause_doc", %{"id" => id}, socket) do
    _ = Scanflow.Batch.pause_document(String.to_integer(id))
    {:noreply, socket}
  end

  @impl true
  def handle_event("resume_doc", %{"id" => id}, socket) do
    _ = Scanflow.Batch.resume_document(String.to_integer(id))
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_doc", %{"id" => id}, socket) do
    doc_id = String.to_integer(id)
    _ = Scanflow.Batch.cancel_document(doc_id)

    {:noreply,
     assign(socket,
       batch_by_id: Map.delete(socket.assigns.batch_by_id, doc_id),
       selected_ids: MapSet.delete(socket.assigns.selected_ids, doc_id)
     )}
  end

  @impl true
  def handle_event("retry_doc", %{"id" => id}, socket) do
    _ = Scanflow.Batch.retry_document(String.to_integer(id))
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(search_query: query, page: 1)
      |> load_documents()

    {:noreply, push_patch(socket, to: "/batch?q=#{URI.encode(query)}")}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    socket =
      socket
      |> assign(search_query: "", page: 1)
      |> load_documents()

    {:noreply, push_patch(socket, to: "/batch")}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    if socket.assigns.next_page do
      page = socket.assigns.next_page
      socket = socket |> assign(page: page) |> load_documents()

      query =
        if socket.assigns.search_query != "",
          do: "?q=#{URI.encode(socket.assigns.search_query)}&page=#{page}",
          else: "?page=#{page}"

      {:noreply, push_patch(socket, to: "/batch#{query}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("previous_page", _params, socket) do
    if socket.assigns.previous_page do
      page = socket.assigns.previous_page
      socket = socket |> assign(page: page) |> load_documents()

      query =
        if socket.assigns.search_query != "",
          do: "?q=#{URI.encode(socket.assigns.search_query)}&page=#{page}",
          else: "?page=#{page}"

      {:noreply, push_patch(socket, to: "/batch#{query}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:document_updated, doc}, socket) do
    {:noreply, assign(socket, batch_by_id: Map.put(socket.assigns.batch_by_id, doc.id, doc))}
  end

  defp load_documents(socket) do
    socket = assign(socket, loading: true, error: nil)

    tags_result = Scanflow.Api.fetch_tags()

    result =
      if socket.assigns.search_query == "" do
        Scanflow.Api.fetch_documents(
          page: socket.assigns.page,
          page_size: socket.assigns.page_size
        )
      else
        Scanflow.Api.search_documents(socket.assigns.search_query,
          page: socket.assigns.page,
          page_size: socket.assigns.page_size
        )
      end

    case {tags_result, result} do
      {{:ok, tags}, {:ok, response}} ->
        previous_page = if socket.assigns.page > 1, do: socket.assigns.page - 1, else: nil
        has_more = response.count > socket.assigns.page * socket.assigns.page_size
        next_page = if has_more, do: socket.assigns.page + 1, else: nil

        assign(socket,
          documents: response.results || [],
          total_count: response.count || 0,
          next_page: next_page || response.next,
          previous_page: response.previous || previous_page,
          tags: tags,
          loading: false,
          error: nil
        )

      {{:error, _}, {:ok, response}} ->
        previous_page = if socket.assigns.page > 1, do: socket.assigns.page - 1, else: nil
        has_more = response.count > socket.assigns.page * socket.assigns.page_size
        next_page = if has_more, do: socket.assigns.page + 1, else: nil

        assign(socket,
          documents: response.results || [],
          total_count: response.count || 0,
          next_page: next_page || response.next,
          previous_page: response.previous || previous_page,
          loading: false,
          error: nil
        )

      {_, {:error, error}} ->
        assign(socket, documents: [], total_count: 0, loading: false, error: error)
    end
  end
end
