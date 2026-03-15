defmodule Scanflow.Automation.SessionWorker do
  use GenServer
  require Logger

  alias Scanflow.Automation.{PdfBuilder, Processor, Scanner}

  def start_link(opts) do
    handler = Keyword.fetch!(opts, :handler)
    session_key = Keyword.fetch!(opts, :session_key)

    GenServer.start_link(__MODULE__, %{handler: handler, session_key: session_key},
      name: via(handler)
    )
  end

  def via(handler), do: {:via, Registry, {Scanflow.Automation.SessionRegistry, handler}}

  def scan_page(handler, session_key),
    do: GenServer.call(via(handler), {:scan_page, session_key}, 180_000)

  def finalize(handler, session_key, opts \\ []),
    do: GenServer.call(via(handler), {:finalize, session_key, opts}, 300_000)

  def state(handler), do: GenServer.call(via(handler), :state)

  @impl true
  def init(%{handler: handler, session_key: session_key}) do
    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "paperless_ha_scan_#{handler}_#{session_key}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)

    Logger.info(
      "SessionWorker init handler=#{handler} session_key=#{session_key} temp_dir=#{temp_dir}"
    )

    {:ok,
     %{
       handler: handler,
       session_key: session_key,
       temp_dir: temp_dir,
       pages: [],
       ocr_tasks: %{},
       total_tokens: 0,
       latest_suggestions: nil,
       latest_suggested_tag_ids: [],
       started_at: DateTime.utc_now(),
       updated_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:scan_page, session_key}, _from, state) do
    if state.session_key != session_key do
      Logger.warning(
        "SessionWorker ignored scan wrong session_key=#{session_key} expected=#{state.session_key}"
      )

      {:reply,
       {:ok, %{status: "ignored_wrong_session_key", expected_session_key: state.session_key}},
       state}
    else
      page_num = length(state.pages) + 1
      Logger.info("SessionWorker scan page=#{page_num} handler=#{state.handler}")

      with {:ok, image_path} <- Scanner.scan_page(state.temp_dir, page_num, state.handler) do
        task =
          Task.Supervisor.async_nolink(Scanflow.AutomationTaskSupervisor, fn ->
            Scanflow.Ocr.extract_text_from_image(image_path, page_num)
          end)

        pages =
          state.pages ++
            [
              %{
                page: page_num,
                image_path: image_path,
                ocr_text: nil,
                tokens: 0,
                ocr_status: :pending
              }
            ]

        updated =
          state
          |> Map.put(:pages, pages)
          |> Map.put(:ocr_tasks, Map.put(state.ocr_tasks, task.ref, page_num))
          |> Map.put(:updated_at, DateTime.utc_now())

        Logger.info("SessionWorker queued OCR page=#{page_num} ref=#{inspect(task.ref)}")

        {:reply,
         {:ok,
          %{
            status: "scanned",
            page: page_num,
            session_key: updated.session_key,
            ocr_status: "queued",
            pending_ocr_pages: pending_ocr_count(updated)
          }}, updated}
      else
        {:error, error} ->
          Logger.error("SessionWorker scan failed page=#{page_num} error=#{inspect(error)}")
          {:reply, {:error, error}, state}
      end
    end
  end

  @impl true
  def handle_call({:finalize, session_key, opts}, _from, state) do
    send_email = Keyword.get(opts, :send_email, true)
    Logger.info("SessionWorker finalize handler=#{state.handler} session_key=#{session_key}")

    cond do
      state.session_key != session_key ->
        Logger.warning(
          "SessionWorker ignored finalize wrong session_key=#{session_key} expected=#{state.session_key}"
        )

        {:reply,
         {:ok, %{status: "ignored_wrong_session_key", expected_session_key: state.session_key}},
         state}

      state.pages == [] ->
        {:reply, {:error, "No scanned pages in session"}, state}

      pending_ocr_count(state) > 0 ->
        {:reply,
         {:ok,
          %{
            status: "waiting_for_ocr",
            pending_ocr_pages: pending_ocr_count(state)
          }}, state}

      has_failed_ocr?(state) ->
        {:reply, {:error, "One or more pages failed OCR; rescan failed pages"}, state}

      true ->
        image_paths = Enum.map(state.pages, & &1.image_path)
        output_pdf = Path.join(state.temp_dir, "merged.pdf")

        with {:ok, state} <- generate_final_suggestions(state),
             {:ok, pdf_path} <- PdfBuilder.merge_images_to_pdf(image_paths, output_pdf),
             {:ok, upload} <-
               upload_to_paperless(
                 pdf_path,
                 state.handler,
                 state.latest_suggestions,
                 Map.get(state, :latest_suggested_tag_ids, []),
                 full_ocr_text(state)
               ) do
          pdf_size_bytes =
            case File.stat(pdf_path) do
              {:ok, stat} -> stat.size
              _ -> 0
            end

          schedule_post_upload_update(upload, state, pdf_size_bytes, send_email)

          Logger.info(
            "SessionWorker finalize upload success handler=#{state.handler} pages=#{length(state.pages)}"
          )

          cleanup_session_files(state)

          {:stop, :normal,
           {:ok,
            %{
              status: "finalized",
              upload: upload,
              session_key: state.session_key,
              handler: state.handler,
              pages: length(state.pages)
            }}, state}
        else
          {:error, error} ->
            Logger.error(
              "SessionWorker finalize failed handler=#{state.handler} error=#{inspect(error)}"
            )

            {:reply, {:error, error}, state}
        end
    end
  end

  @impl true
  def handle_info({ref, ocr_result}, state) when is_reference(ref) do
    case Map.pop(state.ocr_tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {page_num, remaining_tasks} ->
        Process.demonitor(ref, [:flush])

        case ocr_result do
          {:ok, ocr_text} ->
            page_tokens = estimate_tokens(ocr_text)

            updated_pages =
              Enum.map(state.pages, fn page ->
                if page.page == page_num do
                  %{page | ocr_text: ocr_text, tokens: page_tokens, ocr_status: :done}
                else
                  page
                end
              end)

            updated_state =
              state
              |> Map.put(:pages, updated_pages)
              |> Map.put(:ocr_tasks, remaining_tasks)
              |> Map.put(:total_tokens, state.total_tokens + page_tokens)
              |> Map.put(:updated_at, DateTime.utc_now())

            Logger.info(
              "SessionWorker OCR complete page=#{page_num} tokens_total=#{updated_state.total_tokens} pending=#{pending_ocr_count(updated_state)}"
            )

            {:noreply, updated_state}

          {:error, error} ->
            Logger.error("SessionWorker OCR failed page=#{page_num} error=#{inspect(error)}")

            updated_pages =
              Enum.map(state.pages, fn page ->
                if page.page == page_num do
                  %{page | ocr_status: :failed, ocr_error: error}
                else
                  page
                end
              end)

            {:noreply,
             state
             |> Map.put(:pages, updated_pages)
             |> Map.put(:ocr_tasks, remaining_tasks)
             |> Map.put(:updated_at, DateTime.utc_now())}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.ocr_tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {page_num, remaining_tasks} ->
        Logger.error("SessionWorker OCR task DOWN page=#{page_num} reason=#{inspect(reason)}")

        updated_pages =
          Enum.map(state.pages, fn page ->
            if page.page == page_num do
              %{page | ocr_status: :failed, ocr_error: inspect(reason)}
            else
              page
            end
          end)

        {:noreply,
         state
         |> Map.put(:pages, updated_pages)
         |> Map.put(:ocr_tasks, remaining_tasks)
         |> Map.put(:updated_at, DateTime.utc_now())}
    end
  end

  defp generate_final_suggestions(state) do
    Logger.info("SessionWorker generating final suggestions from all scanned pages")

    with {:ok, tags} <- Scanflow.Api.fetch_tags(),
         {:ok, suggestions} <-
           Scanflow.AiSuggestions.get_suggestions(full_ocr_text(state), tags) do
      suggested_tag_ids =
        (suggestions.tags || [])
        |> Enum.map(fn tag_name ->
          tags
          |> Enum.find(fn {_id, tag} -> tag["name"] == tag_name end)
          |> case do
            {id, _} -> id
            nil -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      updated_state =
        state
        |> Map.put(:latest_suggestions, suggestions)
        |> Map.put(:latest_suggested_tag_ids, suggested_tag_ids)
        |> Map.put(:updated_at, DateTime.utc_now())

      {:ok, updated_state}
    end
  end

  defp estimate_tokens(text) when is_binary(text) do
    text
    |> String.length()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
  end

  defp full_ocr_text(state) do
    state.pages
    |> Enum.filter(fn page -> is_binary(page.ocr_text) and page.ocr_text != "" end)
    |> Enum.map(fn page -> "--- Page #{page.page} ---\n\n#{page.ocr_text}" end)
    |> Enum.join("\n\n")
  end

  defp pending_ocr_count(state) do
    state.pages
    |> Enum.count(fn page -> Map.get(page, :ocr_status) == :pending end)
  end

  defp has_failed_ocr?(state) do
    Enum.any?(state.pages, fn page -> Map.get(page, :ocr_status) == :failed end)
  end

  defp upload_to_paperless(pdf_path, handler, _suggestions, _suggested_tag_ids, _ocr_text) do
    with {:ok, automation_field_id} <-
           Scanflow.Api.ensure_custom_field_id("ha-paperless-automation", "boolean"),
         {:ok, handler_field_id} <- Scanflow.Api.ensure_custom_field_id("ha-handler", "string") do
      custom_fields = [
        %{"field" => automation_field_id, "value" => true},
        %{"field" => handler_field_id, "value" => handler}
      ]

      Scanflow.Api.upload_document(pdf_path,
        title: Path.basename(pdf_path, ".pdf"),
        custom_fields: custom_fields,
        content: nil,
        tags: []
      )
    end
  end

  defp schedule_post_upload_update(upload_response, state, pdf_size_bytes, send_email) do
    task_id = extract_upload_task_id(upload_response)

    if is_binary(task_id) and task_id != "" do
      suggestions = state.latest_suggestions || %{}
      title = suggestions.title
      tag_ids = Map.get(state, :latest_suggested_tag_ids, [])
      ocr_text = full_ocr_text(state)

      _ =
        Task.Supervisor.start_child(Scanflow.AutomationTaskSupervisor, fn ->
          Logger.info("SessionWorker post-upload waiting for task_id=#{task_id}")

          case Scanflow.Api.wait_for_task_document(task_id,
                 timeout_ms: 240_000,
                 poll_interval_ms: 1000
               ) do
            {:ok, document_id} ->
              Logger.info(
                "SessionWorker post-upload task complete task_id=#{task_id} document_id=#{document_id}"
              )

              attrs = %{
                "content" => ocr_text,
                "tags" => tag_ids
              }

              attrs =
                if is_binary(title) and String.trim(title) != "",
                  do: Map.put(attrs, "title", title),
                  else: attrs

              case Scanflow.Api.update_document(document_id, attrs) do
                {:ok, _} ->
                  Logger.info(
                    "SessionWorker post-upload applied LLM metadata document_id=#{document_id}"
                  )

                  case Processor.process_document(document_id,
                         file_size_bytes: pdf_size_bytes,
                         send_email: send_email
                       ) do
                    :ok ->
                      Logger.info(
                        "SessionWorker post-upload email automation completed document_id=#{document_id}"
                      )

                    {:ok, :ignored_not_automation_document} ->
                      Logger.info(
                        "SessionWorker post-upload email automation ignored document_id=#{document_id}"
                      )

                    {:error, error} ->
                      Logger.error(
                        "SessionWorker post-upload email automation failed document_id=#{document_id} error=#{inspect(error)}"
                      )
                  end

                {:error, error} ->
                  Logger.error(
                    "SessionWorker post-upload update failed document_id=#{document_id} error=#{inspect(error)}"
                  )
              end

            {:error, error} ->
              Logger.error(
                "SessionWorker post-upload task wait failed task_id=#{task_id} error=#{inspect(error)}"
              )
          end
        end)
    else
      Logger.warning(
        "SessionWorker could not extract task id from upload response=#{inspect(upload_response, limit: 500)}"
      )
    end
  end

  defp extract_upload_task_id(upload_response) when is_map(upload_response) do
    candidates = [
      upload_response["task_id"],
      upload_response["task"],
      upload_response["id"],
      upload_response["uuid"],
      get_in(upload_response, ["data", "task_id"]),
      get_in(upload_response, ["task", "task_id"])
    ]

    candidates
    |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  defp extract_upload_task_id(upload_response) when is_binary(upload_response) do
    value = String.trim(upload_response)
    if value == "", do: nil, else: value
  end

  defp extract_upload_task_id(_), do: nil

  defp cleanup_session_files(state) do
    Enum.each(state.pages, fn page ->
      _ = File.rm(page.image_path)
    end)

    _ = File.rm(Path.join(state.temp_dir, "merged.pdf"))
    _ = File.rmdir(state.temp_dir)
  end
end
