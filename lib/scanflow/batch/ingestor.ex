defmodule Scanflow.Batch.Ingestor do
  alias Scanflow.Batch

  def process_documents(documents) when is_list(documents) do
    max_concurrency = Batch.config(:prep_max_concurrency, 4)

    Task.Supervisor.async_stream_nolink(
      Scanflow.BatchPrepTaskSupervisor,
      documents,
      &process_document/1,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp process_document(doc) do
    if halted?(doc.id) do
      :ok
    else
      doc = enrich_document_from_api(doc)
      Batch.update_document(doc.id, fn _ -> doc end)

      Batch.update_document(doc.id, %{status: "downloading", status_detail: "Downloading PDF..."})

      with {:ok, pdf_path} <- Scanflow.Api.download_pdf(doc.id),
           _ <-
             Batch.update_document(doc.id, %{
               status: "extracting_images",
               status_detail: "Extracting images..."
             }),
           {:ok, image_paths} <-
             Scanflow.Ocr.convert_pdf_pages(pdf_path, fn msg ->
               Batch.update_document(doc.id, %{status_detail: msg})
             end) do
        File.rm(pdf_path)

        prepared =
          %{
            doc
            | pdf_path: pdf_path,
              image_paths: image_paths,
              status: "queued_for_ocr",
              failed_stage: nil
          }

        Batch.update_document(doc.id, fn _ -> prepared end)

        cond do
          canceled?(doc.id) ->
            Enum.each(image_paths, &File.rm/1)

            Batch.update_document(doc.id, %{status: "canceled", status_detail: "Canceled by user"})

          paused?(doc.id) ->
            Batch.update_document(doc.id, %{status: "paused", status_detail: "Paused"})

          true ->
            Batch.update_document(doc.id, %{status_detail: "Queued"})
            Scanflow.Batch.OcrProducer.enqueue(prepared)
        end
      else
        {:error, error} ->
          Batch.update_document(doc.id, %{
            status: "failed",
            error: error,
            status_detail: "Preparation failed",
            failed_stage: :prep
          })
      end
    end
  end

  defp enrich_document_from_api(doc) do
    case Scanflow.Api.fetch_document(doc.id) do
      {:ok, full_doc} ->
        %{
          doc
          | title: full_doc.title,
            original_file_name: full_doc.original_file_name,
            current_tags: full_doc.tags || doc.current_tags,
            current_content: full_doc.content,
            content_snapshot_loaded: true
        }

      _ ->
        doc
    end
  end

  defp halted?(id), do: paused?(id) or canceled?(id)

  defp paused?(id) do
    case Batch.get_document(id) do
      %{paused: true} -> true
      _ -> false
    end
  end

  defp canceled?(id) do
    case Batch.get_document(id) do
      %{canceled: true} -> true
      _ -> false
    end
  end
end
