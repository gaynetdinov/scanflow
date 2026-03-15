defmodule ScanflowWeb.DocumentLive.Show do
  use ScanflowWeb, :live_view

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Scanflow.Batch.subscribe()

    doc_id = String.to_integer(id)
    batch_doc = Scanflow.Batch.get_document(doc_id)

    socket =
      assign(socket,
        document_id: doc_id,
        paperless_doc_url: paperless_document_url(doc_id),
        llm_mode: get_llm_mode(),
        batch_doc: batch_doc,
        document: nil,
        tags: %{},
        tags_list_for_js: [],
        ocr_text: nil,
        edited_ocr_text: nil,
        ocr_loading: false,
        ocr_error: nil,
        ai_suggestions: nil,
        ai_loading: false,
        ai_error: nil,
        edited_suggested_title: nil,
        processing_status: nil,
        # Editable suggested tags (can be modified by user)
        editable_suggested_tags: [],
        # Suggestion checkboxes (for applying selectively)
        apply_title_suggestion: false,
        apply_tags_suggestion: false,
        apply_content_suggestion: false,
        update_loading: false,
        update_error: nil,
        update_success: nil,
        loading: true,
        error: nil
      )
      |> load_document()
      |> maybe_load_from_batch_state(batch_doc)

    {:ok, socket}
  end

  @impl true
  def handle_event("run_ocr", _params, socket) do
    document = socket.assigns.document

    if is_pdf?(document) do
      parent = self()

      socket =
        assign(socket,
          ocr_loading: true,
          ocr_error: nil,
          processing_status: "Downloading PDF..."
        )

      Task.async(fn ->
        case run_ocr(socket.assigns.document_id, fn status ->
               send(parent, {:processing_status, status})
             end) do
          {:ok, text} -> {:ocr_complete, text}
          {:error, error} -> {:ocr_error, error}
        end
      end)

      {:noreply, socket}
    else
      {:noreply, assign(socket, ocr_error: "Document is not a PDF")}
    end
  end

  @impl true
  def handle_event("run_ocr_and_suggest", _params, socket) do
    document = socket.assigns.document

    if is_pdf?(document) do
      parent = self()

      socket =
        assign(socket,
          ocr_loading: true,
          ai_loading: true,
          ocr_error: nil,
          ai_error: nil,
          update_success: nil,
          processing_status: "Downloading PDF..."
        )

      Task.async(fn ->
        case run_ocr_and_suggestions(socket.assigns.document_id, socket.assigns.tags, fn status ->
               send(parent, {:processing_status, status})
             end) do
          {:ok, text, suggestions} -> {:visual_flow_complete, text, suggestions}
          {:error, error} -> {:visual_flow_error, error}
        end
      end)

      {:noreply, socket}
    else
      {:noreply, assign(socket, ocr_error: "Document is not a PDF")}
    end
  end

  @impl true
  def handle_event("get_ai_suggestions", _params, socket) do
    ocr_text = current_ocr_text(socket)
    tags = socket.assigns.tags

    if ocr_text && ocr_text != "" do
      socket = assign(socket, ai_loading: true, ai_error: nil)

      Task.async(fn ->
        case Scanflow.AiSuggestions.get_suggestions(ocr_text, tags) do
          {:ok, suggestions} -> {:ai_suggestions_complete, suggestions}
          {:error, error} -> {:ai_suggestions_error, error}
        end
      end)

      {:noreply, socket}
    else
      {:noreply, assign(socket, ai_error: "No OCR text available for analysis")}
    end
  end

  @impl true
  def handle_event("update_ocr_text", params, socket) do
    value = Map.get(params, "ocr_text") || Map.get(params, "value") || ""
    {:noreply, assign(socket, edited_ocr_text: value)}
  end

  @impl true
  def handle_event("update_suggested_title", %{"suggested_title" => value}, socket) do
    {:noreply, assign(socket, edited_suggested_title: value)}
  end

  @impl true
  def handle_event("toggle_suggestion", %{"field" => field}, socket) do
    current = Map.get(socket.assigns, String.to_atom("apply_#{field}_suggestion"))
    {:noreply, assign(socket, String.to_atom("apply_#{field}_suggestion"), !current)}
  end

  @impl true
  def handle_event("remove_suggested_tag", %{"tag_name" => tag_name}, socket) do
    current_tags = socket.assigns.editable_suggested_tags
    new_tags = List.delete(current_tags, tag_name)
    {:noreply, assign(socket, editable_suggested_tags: new_tags)}
  end

  @impl true
  def handle_event("add_suggested_tag", %{"tag_id" => tag_id}, socket) do
    tag_id = String.to_integer(tag_id)
    tag = socket.assigns.tags[tag_id]

    if tag do
      tag_name = tag["name"]
      current_tags = socket.assigns.editable_suggested_tags

      if tag_name not in current_tags do
        {:noreply, assign(socket, editable_suggested_tags: [tag_name | current_tags])}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("apply_suggestions", _params, socket) do
    socket = assign(socket, update_loading: true, update_error: nil, update_success: nil)

    attrs = build_update_attrs(socket)

    case Scanflow.Api.update_document(socket.assigns.document_id, attrs) do
      {:ok, updated_doc} ->
        {:noreply,
         socket
         |> assign(
           document: updated_doc,
           update_loading: false,
           update_success: "Document updated successfully",
           editable_suggested_tags: [],
           apply_title_suggestion: false,
           apply_tags_suggestion: false,
           apply_content_suggestion: false
         )
         |> put_flash(:info, "Document updated successfully")}

      {:error, error} ->
        {:noreply, assign(socket, update_loading: false, update_error: error)}
    end
  end

  @impl true
  def handle_info({ref, {:ocr_complete, text}}, socket) when is_reference(ref) do
    {:noreply,
     assign(socket,
       ocr_text: text,
       edited_ocr_text: text,
       ocr_loading: false,
       processing_status: nil
     )}
  end

  @impl true
  def handle_info({ref, {:ocr_error, error}}, socket) when is_reference(ref) do
    {:noreply, assign(socket, ocr_error: error, ocr_loading: false, processing_status: nil)}
  end

  @impl true
  def handle_info({:processing_status, status}, socket) do
    {:noreply, assign(socket, processing_status: status)}
  end

  @impl true
  def handle_info({ref, {:visual_flow_complete, text, suggestions}}, socket)
      when is_reference(ref) do
    suggested_tag_names = suggestions.tags || []

    {:noreply,
     assign(socket,
       ocr_text: text,
       edited_ocr_text: text,
       ai_suggestions: suggestions,
       edited_suggested_title: suggestions.title,
       editable_suggested_tags: suggested_tag_names,
       ocr_loading: false,
       ai_loading: false,
       processing_status: nil
     )}
  end

  @impl true
  def handle_info({ref, {:visual_flow_error, error}}, socket) when is_reference(ref) do
    {:noreply,
     assign(socket,
       ocr_error: error,
       ai_error: error,
       ocr_loading: false,
       ai_loading: false,
       processing_status: nil
     )}
  end

  @impl true
  def handle_info({ref, {:ai_suggestions_complete, suggestions}}, socket)
      when is_reference(ref) do
    # Initialize editable_suggested_tags with AI suggestions
    suggested_tag_names = suggestions.tags || []

    {:noreply,
     assign(socket,
       ai_suggestions: suggestions,
       edited_suggested_title: suggestions.title,
       ai_loading: false,
       editable_suggested_tags: suggested_tag_names
     )}
  end

  @impl true
  def handle_info({ref, {:ai_suggestions_error, error}}, socket) when is_reference(ref) do
    {:noreply, assign(socket, ai_error: error, ai_loading: false)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:document_updated, batch_doc}, socket) do
    if batch_doc.id == socket.assigns.document_id do
      {:noreply,
       socket
       |> assign(batch_doc: batch_doc)
       |> maybe_load_from_batch_state(batch_doc)}
    else
      {:noreply, socket}
    end
  end

  defp load_document(socket) do
    socket = assign(socket, loading: true, error: nil)

    doc_task = Task.async(fn -> Scanflow.Api.fetch_document(socket.assigns.document_id) end)
    tags_task = Task.async(fn -> Scanflow.Api.fetch_tags() end)

    doc_result = Task.await(doc_task, 10_000)
    tags_result = Task.await(tags_task, 10_000)

    case {doc_result, tags_result} do
      {{:ok, document}, {:ok, tags}} ->
        tags_list = build_tags_list_for_js(tags)

        assign(socket,
          document: document,
          tags: tags,
          tags_list_for_js: tags_list,
          loading: false,
          error: nil
        )

      {{:ok, document}, _} ->
        assign(socket,
          document: document,
          tags: %{},
          tags_list_for_js: [],
          loading: false,
          error: nil
        )

      {{:error, error}, _} ->
        assign(socket,
          document: nil,
          loading: false,
          error: error
        )

      _ ->
        assign(socket,
          document: nil,
          loading: false,
          error: "Failed to load document"
        )
    end
  end

  defp is_pdf?(document) do
    file_name = document[:original_file_name] || ""
    String.ends_with?(String.downcase(file_name), ".pdf")
  end

  defp build_tags_list_for_js(tags) do
    tags
    |> Map.values()
    |> Enum.map(fn tag ->
      %{
        "id" => tag["id"],
        "name" => tag["name"],
        "color" => tag["color"] || "#e5e7eb"
      }
    end)
  end

  defp run_ocr(document_id, on_progress) do
    with {:ok, pdf_path} <- Scanflow.Api.download_pdf(document_id),
         {:ok, text} <- Scanflow.Ocr.extract_text_from_pdf(pdf_path, on_progress: on_progress) do
      File.rm(pdf_path)
      {:ok, text}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp run_ocr_and_suggestions(document_id, tags, on_progress) do
    with {:ok, text} <- run_ocr(document_id, on_progress),
         _ <- on_progress.("Generating suggestions..."),
         {:ok, suggestions} <- Scanflow.AiSuggestions.get_suggestions(text, tags) do
      {:ok, text, suggestions}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp get_llm_mode do
    Application.get_env(:scanflow, :llm_mode, :separate)
  end

  defp paperless_document_url(id) do
    endpoint =
      Application.get_env(:scanflow, :paperless_api, [])
      |> Keyword.get(:endpoint, "")
      |> String.trim_trailing("/")

    if endpoint == "" do
      nil
    else
      "#{endpoint}/documents/#{id}/details"
    end
  end

  defp maybe_load_from_batch_state(socket, nil), do: socket

  defp maybe_load_from_batch_state(socket, batch_doc) do
    socket
    |> assign(ocr_text: batch_doc.ocr_text || socket.assigns.ocr_text)
    |> assign(edited_ocr_text: batch_doc.ocr_text || socket.assigns.edited_ocr_text)
    |> assign(
      ai_suggestions:
        if(batch_doc.suggested_title || (batch_doc.suggested_tags || []) != [],
          do: %{title: batch_doc.suggested_title, tags: batch_doc.suggested_tags || []},
          else: socket.assigns.ai_suggestions
        )
    )
    |> assign(
      edited_suggested_title: batch_doc.suggested_title || socket.assigns.edited_suggested_title,
      editable_suggested_tags:
        if((batch_doc.suggested_tags || []) != [],
          do: batch_doc.suggested_tags,
          else: socket.assigns.editable_suggested_tags
        ),
      apply_title_suggestion:
        Map.get(batch_doc, :apply_title_suggestion, socket.assigns.apply_title_suggestion),
      apply_tags_suggestion:
        Map.get(batch_doc, :apply_tags_suggestion, socket.assigns.apply_tags_suggestion),
      apply_content_suggestion:
        Map.get(batch_doc, :apply_content_suggestion, socket.assigns.apply_content_suggestion)
    )
  end

  defp build_update_attrs(socket) do
    document = socket.assigns.document
    suggestions = socket.assigns.ai_suggestions

    attrs = %{}

    attrs =
      if socket.assigns.apply_title_suggestion && suggestions && suggestions.title do
        Map.put(attrs, "title", socket.assigns.edited_suggested_title || suggestions.title)
      else
        Map.put(attrs, "title", document.title)
      end

    attrs =
      if socket.assigns.apply_content_suggestion && current_ocr_text(socket) do
        Map.put(attrs, "content", current_ocr_text(socket))
      else
        Map.put(attrs, "content", document.content)
      end

    attrs =
      if socket.assigns.apply_tags_suggestion && socket.assigns.editable_suggested_tags != [] do
        suggested_tag_ids =
          socket.assigns.editable_suggested_tags
          |> Enum.map(fn tag_name ->
            socket.assigns.tags
            |> Enum.find(fn {_id, tag} -> tag["name"] == tag_name end)
            |> case do
              {id, _} -> id
              nil -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        # Replace existing tags with selected suggested tags
        Map.put(attrs, "tags", Enum.uniq(suggested_tag_ids))
      else
        Map.put(attrs, "tags", document.tags)
      end

    attrs
  end

  defp current_ocr_text(socket) do
    socket.assigns.edited_ocr_text || socket.assigns.ocr_text
  end
end
