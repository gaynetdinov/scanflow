defmodule Scanflow.Batch.OcrConsumer do
  use GenStage

  alias Scanflow.Batch

  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    {:consumer, %{name: name},
     subscribe_to: [
       {Scanflow.Batch.OcrProducer, max_demand: 1, min_demand: 0}
     ]}
  end

  @impl true
  def handle_events(documents, _from, state) do
    Enum.each(documents, &process_document/1)
    {:noreply, [], state}
  end

  defp process_document(doc) do
    cond do
      canceled?(doc.id) ->
        Enum.each(doc.image_paths || [], &File.rm/1)
        Batch.update_document(doc.id, %{status: "canceled", status_detail: "Canceled by user"})

      paused?(doc.id) ->
        Batch.update_document(doc.id, %{status: "paused", status_detail: "Paused"})

      true ->
        Batch.update_document(doc.id, %{
          status: "ocr_in_progress",
          status_detail: "Calling OCR LLM..."
        })

        case Scanflow.Ocr.process_images(doc.image_paths, fn msg ->
               Batch.update_document(doc.id, %{status_detail: msg})
             end) do
          {:ok, text} ->
            Enum.each(doc.image_paths, &File.rm/1)

            updated_doc = %{
              doc
              | ocr_text: text,
                status: "ocr_done",
                status_detail: "OCR completed",
                failed_stage: nil
            }

            Batch.update_document(doc.id, fn _ -> updated_doc end)

            cond do
              canceled?(doc.id) ->
                Batch.update_document(doc.id, %{
                  status: "canceled",
                  status_detail: "Canceled by user"
                })

              paused?(doc.id) ->
                Batch.update_document(doc.id, %{status: "paused", status_detail: "Paused"})

              true ->
                Batch.update_document(doc.id, %{
                  status: "queued_for_suggestions",
                  status_detail: "Queued"
                })

                Scanflow.Batch.SuggestionProducer.enqueue(updated_doc)
            end

          {:error, error} ->
            Batch.update_document(doc.id, %{
              status: "failed",
              error: error,
              status_detail: "OCR failed",
              failed_stage: :ocr
            })
        end
    end
  end

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
