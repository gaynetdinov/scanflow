defmodule ScanflowWeb.DocumentsLive do
  use ScanflowWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Scanflow.Batch.subscribe()

    batch_by_id =
      Scanflow.Batch.list_documents()
      |> Map.new(&{&1.id, &1})

    socket =
      assign(socket,
        documents: [],
        selected_ids: MapSet.new(),
        batch_by_id: batch_by_id,
        include_processed: false,
        ai_processed_field_id: nil,
        page: 1,
        page_size: 25,
        total_count: 0,
        next_page: nil,
        previous_page: nil,
        search_query: "",
        loading: true,
        error: nil,
        mounted: false,
        tags: %{},
        paperless_api_endpoint:
          Application.get_env(:scanflow, :paperless_api, [])
          |> Keyword.get(:endpoint, "")
          |> String.trim_trailing("/")
      )

    socket =
      case Scanflow.Api.ensure_ai_processed_field_id() do
        {:ok, field_id} -> assign(socket, ai_processed_field_id: field_id)
        _ -> socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = String.to_integer(params["page"] || "1")
    query = params["q"] || ""
    include_processed = params["include_processed"] == "1"

    # Only load documents if params are different from current assigns
    # or if this is the first time (mounted is false)
    if !socket.assigns.mounted || socket.assigns.page != page ||
         socket.assigns.search_query != query ||
         socket.assigns.include_processed != include_processed do
      socket =
        socket
        |> assign(
          page: page,
          search_query: query,
          include_processed: include_processed,
          mounted: true
        )
        |> load_documents()

      {:noreply, socket}
    else
      {:noreply, assign(socket, mounted: true)}
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
  def handle_event("process_selected", _params, socket) do
    selected_docs =
      socket.assigns.documents
      |> Enum.filter(fn doc -> MapSet.member?(socket.assigns.selected_ids, doc.id) end)

    if selected_docs != [] do
      _ = Scanflow.Batch.enqueue_documents(selected_docs)
    end

    {:noreply, assign(socket, selected_ids: MapSet.new())}
  end

  @impl true
  def handle_event("hide_selected", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    errors =
      selected_ids
      |> Enum.map(fn id -> Scanflow.Api.set_ai_processed(id, true) end)
      |> Enum.filter(fn result -> match?({:error, _}, result) end)

    socket =
      socket
      |> assign(selected_ids: MapSet.new())
      |> load_documents()

    case errors do
      [] ->
        {:noreply, socket}

      [{:error, error} | _] ->
        {:noreply, assign(socket, error: error)}
    end
  end

  @impl true
  def handle_event("toggle_include_processed", _params, socket) do
    include_processed = !socket.assigns.include_processed
    socket = assign(socket, include_processed: include_processed, page: 1) |> load_documents()

    path = build_path(socket.assigns.search_query, 1, include_processed)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("hide_document", %{"id" => id}, socket) do
    doc_id = String.to_integer(id)

    case Scanflow.Api.set_ai_processed(doc_id, true) do
      {:ok, _} ->
        socket =
          socket
          |> assign(selected_ids: MapSet.delete(socket.assigns.selected_ids, doc_id))
          |> load_documents()

        {:noreply, socket}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(search_query: query, page: 1)
      |> load_documents()

    {:noreply, push_patch(socket, to: build_path(query, 1, socket.assigns.include_processed))}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    socket
    |> assign(search_query: "", page: 1)
    |> load_documents()
    |> then(fn socket ->
      {:noreply, push_patch(socket, to: build_path("", 1, socket.assigns.include_processed))}
    end)
  end

  @impl true
  def handle_event("go_to_page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)

    socket
    |> assign(page: page)
    |> load_documents()
    |> then(fn socket ->
      query =
        build_path(socket.assigns.search_query, page, socket.assigns.include_processed)

      {:noreply, push_patch(socket, to: query)}
    end)
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    if socket.assigns.next_page do
      page = socket.assigns.next_page

      socket =
        socket
        |> assign(page: page)
        |> load_documents()

      query =
        build_path(socket.assigns.search_query, page, socket.assigns.include_processed)

      {:noreply, push_patch(socket, to: query)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("previous_page", _params, socket) do
    if socket.assigns.previous_page do
      page = socket.assigns.previous_page

      socket =
        socket
        |> assign(page: page)
        |> load_documents()

      query =
        build_path(socket.assigns.search_query, page, socket.assigns.include_processed)

      {:noreply, push_patch(socket, to: query)}
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

    # Fetch tags if not already loaded
    tags_result = Scanflow.Api.fetch_tags()

    docs_result = fetch_documents_for_display(socket)

    case {tags_result, docs_result} do
      {{:ok, tags}, {:ok, response}} ->
        assign(socket,
          documents: response.results || [],
          total_count: response.count || 0,
          next_page: response.next,
          previous_page: response.previous,
          loading: false,
          error: nil,
          tags: tags
        )

      {_, {:error, error}} ->
        # Keep existing pagination on error so user can retry
        assign(socket,
          documents: [],
          total_count: 0,
          loading: false,
          error: error
        )

      {{:error, _}, _} ->
        # Tags failed but we can still show documents
        case docs_result do
          {:ok, response} ->
            assign(socket,
              documents: response.results || [],
              total_count: response.count || 0,
              next_page: response.next,
              previous_page: response.previous,
              loading: false,
              error: nil,
              tags: socket.assigns.tags
            )

          {:error, error} ->
            assign(socket,
              documents: [],
              total_count: 0,
              loading: false,
              error: error,
              tags: socket.assigns.tags
            )
        end

      _ ->
        # Keep existing pagination on error so user can retry
        assign(socket,
          documents: [],
          total_count: 0,
          loading: false,
          error: "Unexpected response"
        )
    end
  end

  defp filter_documents(documents, socket) do
    if socket.assigns.include_processed do
      documents
    else
      Enum.reject(documents, &document_ai_processed?(&1, socket.assigns.ai_processed_field_id))
    end
  end

  defp document_ai_processed?(doc, nil) do
    _ = doc
    false
  end

  defp document_ai_processed?(doc, field_id) do
    custom_fields = normalize_custom_fields(doc.custom_fields)

    value =
      Map.get(custom_fields, field_id) || Map.get(custom_fields, Integer.to_string(field_id))

    value in [true, "true", 1, "1"]
  end

  defp normalize_custom_fields(nil), do: %{}
  defp normalize_custom_fields(fields) when is_map(fields), do: fields

  defp normalize_custom_fields(fields) when is_list(fields) do
    Enum.reduce(fields, %{}, fn
      %{"field" => id, "value" => value}, acc -> Map.put(acc, id, value)
      %{"custom_field" => id, "value" => value}, acc -> Map.put(acc, id, value)
      %{field: id, value: value}, acc -> Map.put(acc, id, value)
      %{custom_field: id, value: value}, acc -> Map.put(acc, id, value)
      _other, acc -> acc
    end)
  end

  defp normalize_custom_fields(_), do: %{}

  defp fetch_documents_for_display(socket) do
    with {:ok, response} <- fetch_documents_page(socket, socket.assigns.page) do
      if socket.assigns.include_processed do
        {:ok, response}
      else
        collect_visible_documents(socket, response, [], response.count || 0)
      end
    end
  end

  defp fetch_documents_page(socket, page) do
    if socket.assigns.search_query == "" do
      Scanflow.Api.fetch_documents(page: page, page_size: socket.assigns.page_size)
    else
      Scanflow.Api.search_documents(socket.assigns.search_query,
        page: page,
        page_size: socket.assigns.page_size
      )
    end
  end

  defp collect_visible_documents(socket, response, acc, total_count) do
    visible = filter_documents(response.results || [], socket)
    collected = acc ++ visible

    cond do
      length(collected) >= socket.assigns.page_size ->
        {:ok,
         %{
           count: total_count,
           previous: if(socket.assigns.page > 1, do: socket.assigns.page - 1, else: nil),
           next: response.next,
           results: Enum.take(collected, socket.assigns.page_size)
         }}

      is_nil(response.next) ->
        {:ok,
         %{
           count: total_count,
           previous: if(socket.assigns.page > 1, do: socket.assigns.page - 1, else: nil),
           next: nil,
           results: collected
         }}

      true ->
        case fetch_documents_page(socket, response.next) do
          {:ok, next_response} -> collect_visible_documents(socket, next_response, collected, total_count)
          {:error, error} -> {:error, error}
        end
    end
  end

  defp build_path(query, page, include_processed) do
    params = []
    params = if query != "", do: [{"q", query} | params], else: params
    params = if page > 1, do: [{"page", Integer.to_string(page)} | params], else: params
    params = if include_processed, do: [{"include_processed", "1"} | params], else: params

    case Enum.reverse(params) do
      [] -> "/"
      list -> "/?" <> URI.encode_query(list)
    end
  end
end
