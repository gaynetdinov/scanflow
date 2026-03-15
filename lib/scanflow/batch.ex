defmodule Scanflow.Batch do
  alias Scanflow.Batch.Document
  alias Scanflow.Batch.DocumentState

  def topic, do: "batch:documents"

  def subscribe, do: Phoenix.PubSub.subscribe(Scanflow.PubSub, topic())

  def config(key, default),
    do: Application.get_env(:scanflow, :batch, []) |> Keyword.get(key, default)

  def enqueue_documents(documents) do
    prepared =
      documents
      |> Enum.map(&Document.from_paperless/1)
      |> Enum.filter(&ensure_document_state/1)

    if prepared != [] do
      case Process.whereis(Scanflow.BatchPrepTaskSupervisor) do
        nil ->
          Task.start(fn ->
            Scanflow.Batch.Ingestor.process_documents(prepared)
          end)

        _pid ->
          Task.Supervisor.start_child(Scanflow.BatchPrepTaskSupervisor, fn ->
            Scanflow.Batch.Ingestor.process_documents(prepared)
          end)
      end
    else
      {:ok, :nothing_to_enqueue}
    end
  end

  def list_documents do
    if registry_ready?() do
      Registry.select(Scanflow.Batch.DocumentRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.map(&get_document/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&normalize_document/1)
      |> Enum.map(&maybe_hydrate_on_read/1)
      |> Enum.sort_by(fn doc ->
        {to_unix(Map.get(doc, :inserted_at) || Map.get(doc, :updated_at)), doc.id}
      end)
    else
      []
    end
  end

  def get_document(id) do
    if registry_ready?() do
      case GenServer.whereis(DocumentState.via(id)) do
        nil -> nil
        _pid -> DocumentState.get(id)
      end
    else
      nil
    end
  end

  def update_document(id, updater) do
    if registry_ready?() do
      case GenServer.whereis(DocumentState.via(id)) do
        nil -> :error
        _pid -> DocumentState.update(id, updater)
      end
    else
      :error
    end
  end

  def hydrate_missing_content(documents) when is_list(documents) do
    _ = documents
    :ok
  end

  def pause_document(id) do
    update_document(id, fn current ->
      %{current | paused: true, status: "paused", status_detail: "Paused", error: nil}
    end)
  end

  def resume_document(id) do
    case get_document(id) do
      %Document{} = doc ->
        update_document(id, fn current ->
          %{current | paused: false, canceled: false, status_detail: "Resumed", error: nil}
        end)

        cond do
          doc.canceled ->
            :ok

          doc.image_paths != [] and is_nil(doc.ocr_text) ->
            update_document(id, %{status: "queued_for_ocr", status_detail: "Queued"})
            Scanflow.Batch.OcrProducer.enqueue(get_document(id))
            :ok

          is_binary(doc.ocr_text) and
              (is_nil(doc.suggested_title) and (doc.suggested_tags || []) == []) ->
            update_document(id, %{status: "queued_for_suggestions", status_detail: "Queued"})
            Scanflow.Batch.SuggestionProducer.enqueue(get_document(id))
            :ok

          true ->
            update_document(id, %{status: "completed", status_detail: "Ready for review"})
            :ok
        end

      _ ->
        {:error, "Document not found"}
    end
  end

  def cancel_document(id) do
    case get_document(id) do
      %Document{} = doc ->
        cleanup_document_files(doc)
        terminate_document_state(id)
        :ok

      _ ->
        {:error, "Document not found"}
    end
  end

  def retry_document(id) do
    case get_document(id) do
      %Document{status: "failed"} = doc ->
        update_document(id, %{
          error: nil,
          paused: false,
          canceled: false,
          status_detail: "Retrying..."
        })

        case doc.failed_stage do
          :prep ->
            case Process.whereis(Scanflow.BatchPrepTaskSupervisor) do
              nil ->
                Task.start(fn ->
                  Scanflow.Batch.Ingestor.process_documents([doc])
                end)

              _pid ->
                Task.Supervisor.start_child(Scanflow.BatchPrepTaskSupervisor, fn ->
                  Scanflow.Batch.Ingestor.process_documents([doc])
                end)
            end

            :ok

          :ocr ->
            update_document(id, %{status: "queued_for_ocr", status_detail: "Queued"})
            Scanflow.Batch.OcrProducer.enqueue(get_document(id))
            :ok

          :suggestion ->
            update_document(id, %{status: "queued_for_suggestions", status_detail: "Queued"})
            Scanflow.Batch.SuggestionProducer.enqueue(get_document(id))
            :ok

          _ ->
            {:error, "Unknown failed stage"}
        end

      %Document{} ->
        {:error, "Document is not in failed state"}

      _ ->
        {:error, "Document not found"}
    end
  end

  def apply_suggestions(document_id) do
    case get_document(document_id) do
      %Document{canceled: true} ->
        {:error, "Document is canceled"}

      %Document{} = doc ->
        mapped_tags = map_suggested_tags_to_ids(doc.suggested_tags)

        attrs = %{
          "title" =>
            if(doc.apply_title_suggestion, do: doc.suggested_title || doc.title, else: doc.title),
          "content" =>
            if(doc.apply_content_suggestion, do: doc.ocr_text, else: doc.current_content),
          "tags" => if(doc.apply_tags_suggestion, do: mapped_tags, else: doc.current_tags)
        }

        update_document(document_id, %{status: "applying", status_detail: "Updating Paperless..."})

        case Scanflow.Api.update_document(document_id, attrs) do
          {:ok, updated} ->
            update_document(document_id, fn current ->
              %{
                current
                | title: updated.title,
                  current_content: updated.content,
                  current_tags: updated.tags || current.current_tags,
                  status: "applied",
                  status_detail: "Applied to Paperless",
                  applied: true
              }
            end)

            :ok

          {:error, error} ->
            update_document(document_id, %{
              status: "failed",
              status_detail: "Apply failed",
              error: error,
              failed_stage: :apply
            })

            {:error, error}
        end

      _ ->
        {:error, "Document is not available in batch state"}
    end
  end

  defp ensure_document_state(%Document{} = doc) do
    if not registry_ready?() do
      false
    else
      case DynamicSupervisor.start_child(
             Scanflow.Batch.DocumentStateSupervisor,
             {DocumentState, doc}
           ) do
        {:ok, _pid} -> true
        {:error, {:already_started, _pid}} -> false
        {:error, _} -> false
      end
    end
  end

  defp registry_ready? do
    Process.whereis(Scanflow.Batch.DocumentRegistry) != nil
  end

  defp map_suggested_tags_to_ids(suggested_tags) do
    case Scanflow.Api.fetch_tags() do
      {:ok, tags} ->
        suggested_tags
        |> Enum.map(fn tag_name ->
          tags
          |> Enum.find(fn {_id, tag} -> tag["name"] == tag_name end)
          |> case do
            {id, _} -> id
            nil -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp cleanup_document_files(doc) do
    (doc.image_paths || [])
    |> Enum.each(fn path ->
      _ = File.rm(path)
    end)

    if is_binary(doc.pdf_path) do
      _ = File.rm(doc.pdf_path)
    end
  end

  defp terminate_document_state(id) do
    case GenServer.whereis(DocumentState.via(id)) do
      nil ->
        :ok

      pid ->
        _ = DynamicSupervisor.terminate_child(Scanflow.Batch.DocumentStateSupervisor, pid)
        :ok
    end
  end

  defp to_unix(nil), do: 0
  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp normalize_document(%Document{} = doc) do
    doc
    |> Map.from_struct()
    |> then(&struct(Document, &1))
  end

  defp normalize_document(doc), do: doc

  defp maybe_hydrate_on_read(%Document{content_snapshot_loaded: true} = doc), do: doc

  defp maybe_hydrate_on_read(%Document{} = doc) do
    case Scanflow.Api.fetch_document(doc.id) do
      {:ok, full_doc} ->
        hydrated =
          %{
            doc
            | title: full_doc.title,
              original_file_name: full_doc.original_file_name,
              current_tags: full_doc.tags || doc.current_tags,
              current_content: full_doc.content,
              content_snapshot_loaded: true
          }

        update_document(doc.id, fn _ -> hydrated end)
        hydrated

      _ ->
        hydrated = %{doc | content_snapshot_loaded: true}
        update_document(doc.id, fn _ -> hydrated end)
        hydrated
    end
  end

  defp maybe_hydrate_on_read(doc), do: doc
end
