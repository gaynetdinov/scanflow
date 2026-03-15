defmodule Scanflow.Batch.SuggestionConsumer do
  use GenStage

  alias Scanflow.Batch

  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    {:consumer, %{name: name},
     subscribe_to: [
       {Scanflow.Batch.SuggestionProducer, max_demand: 1, min_demand: 0}
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
        Batch.update_document(doc.id, %{status: "canceled", status_detail: "Canceled by user"})

      paused?(doc.id) ->
        Batch.update_document(doc.id, %{status: "paused", status_detail: "Paused"})

      true ->
        Batch.update_document(doc.id, %{
          status: "suggesting",
          status_detail: "Generating title and tags..."
        })

        with {:ok, tags} <- Scanflow.Api.fetch_tags(),
             {:ok, suggestions} <-
               Scanflow.AiSuggestions.get_suggestions(doc.ocr_text || "", tags) do
          if canceled?(doc.id) do
            Batch.update_document(doc.id, %{status: "canceled", status_detail: "Canceled by user"})
          else
            Batch.update_document(doc.id, fn current ->
              %{
                current
                | suggested_title: suggestions.title,
                  suggested_tags: suggestions.tags || [],
                  status: "completed",
                  status_detail: "Ready for review",
                  failed_stage: nil
              }
            end)
          end
        else
          {:error, error} ->
            Batch.update_document(doc.id, %{
              status: "failed",
              error: error,
              status_detail: "Suggestion failed",
              failed_stage: :suggestion
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
