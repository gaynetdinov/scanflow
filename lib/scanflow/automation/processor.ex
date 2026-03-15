defmodule Scanflow.Automation.Processor do
  require Logger

  @doc """
  Webhook flow used for Paperless workflows.
  Fetch document by id, run OCR with LLM, generate title/tags and update document.
  """
  def process_webhook_document(document_id) do
    Logger.info("Webhook processor started document_id=#{document_id}")

    with {:ok, doc} <- Scanflow.Api.fetch_document(document_id),
         {:ok, ocr_text} <- extract_document_text(doc, document_id),
         {:ok, tags} <- Scanflow.Api.fetch_tags(),
         {:ok, suggestions} <- Scanflow.AiSuggestions.get_suggestions(ocr_text, tags),
         {:ok, _updated} <-
           Scanflow.Api.update_document(
             document_id,
             build_update_attrs(doc, suggestions, ocr_text, tags)
           ),
         {:ok, _} <- Scanflow.Api.set_ai_processed(document_id, true) do
      Logger.info("Webhook processor completed document_id=#{document_id}")
      :ok
    else
      {:error, error} ->
        Logger.error("Webhook processor failed for document #{document_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  def process_document(document_id, opts \\ []) do
    Logger.info("Automation processor started document_id=#{document_id}")

    with {:ok, doc} <- Scanflow.Api.fetch_document(document_id),
         {:ok, automation_field_id} <-
           Scanflow.Api.ensure_custom_field_id("ha-paperless-automation", "boolean"),
         true <- custom_field_truthy?(doc.custom_fields, automation_field_id),
         {:ok, handler_field_id} <- Scanflow.Api.ensure_custom_field_id("ha-handler", "string"),
         handler <- custom_field_value(doc.custom_fields, handler_field_id),
         {:ok, file_size_bytes} <- resolve_file_size(opts),
         {:ok, send_email?} <- resolve_send_email(opts),
         :ok <-
           maybe_send_email(
             document_id,
             handler,
             doc.title || "Scanned document",
             doc.content || "",
             file_size_bytes,
             send_email?
           ),
         {:ok, _} <- Scanflow.Api.set_ai_processed(document_id, true) do
      Logger.info("Automation processor completed document_id=#{document_id}")
      :ok
    else
      false ->
        Logger.info(
          "Automation processor ignored document_id=#{document_id}: missing automation custom field"
        )

        {:ok, :ignored_not_automation_document}

      {:error, error} ->
        Logger.error("Automation processor failed for document #{document_id}: #{error}")
        {:error, error}
    end
  end

  defp extract_document_text(doc, document_id) do
    file_name = String.downcase(doc.original_file_name || "")

    cond do
      String.ends_with?(file_name, ".pdf") ->
        with {:ok, pdf_path} <- Scanflow.Api.download_pdf(document_id),
             {:ok, text} <- Scanflow.Ocr.extract_text_from_pdf(pdf_path) do
          _ = File.rm(pdf_path)
          {:ok, text}
        end

      String.ends_with?(file_name, ".png") or String.ends_with?(file_name, ".jpg") or
          String.ends_with?(file_name, ".jpeg") ->
        with {:ok, binary} <- Scanflow.Api.download_document_binary(document_id),
             {:ok, image_path} <- write_temp_image(binary.body, file_name),
             {:ok, text} <- Scanflow.Ocr.extract_text_from_image(image_path, 1) do
          _ = File.rm(image_path)
          {:ok, text}
        end

      true ->
        # fallback to existing content if OCR of source format is not supported
        if is_binary(doc.content) and String.trim(doc.content) != "" do
          {:ok, doc.content}
        else
          {:error, "Unsupported file type for OCR and no existing content"}
        end
    end
  end

  defp write_temp_image(body, file_name) do
    ext = Path.extname(file_name)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "paperless_webhook_#{System.unique_integer([:positive])}#{ext}"
      )

    case File.write(tmp, body) do
      :ok -> {:ok, tmp}
      {:error, reason} -> {:error, "Failed to write temp image: #{inspect(reason)}"}
    end
  end

  defp build_update_attrs(doc, suggestions, ocr_text, tags) do
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

    attrs = %{
      "content" => ocr_text,
      "tags" => Enum.uniq(suggested_tag_ids)
    }

    if is_binary(suggestions.title) and String.trim(suggestions.title) != "" do
      Map.put(attrs, "title", suggestions.title)
    else
      Map.put(attrs, "title", doc.title)
    end
  end

  defp maybe_send_email(
         document_id,
         handler,
         subject_title,
         body_text,
         file_size_bytes,
         send_email?
       ) do
    if not send_email? do
      Logger.info(
        "Automation processor skipping email for document_id=#{document_id} (send_email=false)"
      )

      :ok
    else
      email = Scanflow.Automation.Config.handler_email_map() |> Map.get(handler)

      Logger.info(
        "Automation processor resolved handler=#{inspect(handler)} email=#{inspect(email)}"
      )

      if is_binary(email) and String.trim(email) != "" do
        subject = "Paperless document: #{subject_title}"
        max_attach = Scanflow.Automation.Config.email_attachment_max_bytes()

        message =
          if file_size_bytes > max_attach do
            case Scanflow.Api.create_share_link(document_id, days: 7, file_version: "archive") do
              {:ok, share} ->
                link = share["url"] || share["slug"] || "(link unavailable)"

                "The document is too big for email attachment. Download it here: #{link}\n\n" <>
                  body_text

              {:error, error} ->
                Logger.error(
                  "Automation processor share link failed document_id=#{document_id}: #{inspect(error)}"
                )

                "The document is too big for email attachment and link generation failed.\n\n" <>
                  body_text
            end
          else
            body_text
          end

        if file_size_bytes > max_attach do
          case Scanflow.Api.send_plain_email(email, subject, message) do
            {:ok, :sent} ->
              Logger.info(
                "Automation processor sent link email document_id=#{document_id} to=#{email}"
              )

              :ok

            {:error, error} ->
              Logger.error(
                "Automation processor failed link email document_id=#{document_id}: #{inspect(error)}"
              )

              {:error, error}
          end
        else
          case Scanflow.Api.send_document_email(document_id, email,
                 message: message,
                 subject: subject
               ) do
            {:ok, :sent} ->
              Logger.info(
                "Automation processor sent email document_id=#{document_id} to=#{email}"
              )

              :ok

            {:error, error} ->
              Logger.error(
                "Automation processor failed email document_id=#{document_id}: #{inspect(error)}"
              )

              {:error, error}
          end
        end
      else
        :ok
      end
    end
  end

  defp resolve_file_size(opts) do
    case Keyword.get(opts, :file_size_bytes) do
      size when is_integer(size) and size >= 0 -> {:ok, size}
      _ -> {:ok, 0}
    end
  end

  defp resolve_send_email(opts) do
    case Keyword.get(opts, :send_email, true) do
      value when value in [true, false] -> {:ok, value}
      _ -> {:ok, true}
    end
  end

  defp custom_field_truthy?(custom_fields, field_id) do
    custom_field_value(custom_fields, field_id) in [true, "true", 1, "1"]
  end

  defp custom_field_value(custom_fields, field_id) when is_map(custom_fields) do
    Map.get(custom_fields, field_id) || Map.get(custom_fields, Integer.to_string(field_id))
  end

  defp custom_field_value(custom_fields, field_id) when is_list(custom_fields) do
    custom_fields
    |> Enum.find(fn item ->
      item_field = item["field"] || item["custom_field"] || item[:field] || item[:custom_field]
      item_field == field_id || to_string(item_field) == Integer.to_string(field_id)
    end)
    |> case do
      nil -> nil
      item -> item["value"] || item[:value]
    end
  end

  defp custom_field_value(_, _), do: nil
end
