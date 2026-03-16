defmodule Scanflow.Ocr do
  @moduledoc """
  OCR functionality using pdf2image and OCR LLM.
  """

  require Logger

  @doc """
  Extract text from a PDF using OCR LLM.
  Processes all pages in the PDF, one page at a time.
  """
  def extract_text_from_pdf(pdf_path, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)

    notify_progress(on_progress, "Extracting images from PDF...")

    with {:ok, images} <- convert_pdf_pages(pdf_path, on_progress),
         {:ok, text} <- process_images(images, on_progress) do
      # Clean up temporary image files
      Enum.each(images, &File.rm/1)
      {:ok, text}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Convert all pages from PDF to images.
  """
  def convert_pdf_pages(pdf_path, on_progress \\ fn _ -> :ok end) do
    Logger.info("OCR converting PDF to images path=#{pdf_path}")
    results = convert_pages_until_end(pdf_path, 1, [], on_progress)

    case results do
      [] ->
        case convert_single_page(pdf_path, 1) do
          {:error, reason} -> {:error, "Failed to convert any pages from PDF: #{inspect(reason)}"}
          _ -> {:error, "Failed to convert any pages from PDF"}
        end

      pages ->
        images = Enum.map(pages, fn {:ok, img} -> img end)
        Logger.info("Converted #{length(images)} pages from PDF")
        notify_progress(on_progress, "Extracted #{length(images)} page images")
        {:ok, images}
    end
  end

  defp convert_pages_until_end(pdf_path, page_num, acc, on_progress) do
    case convert_single_page(pdf_path, page_num) do
      {:ok, image_path} ->
        notify_progress(on_progress, "Extracted image for page #{page_num}")
        convert_pages_until_end(pdf_path, page_num + 1, [{:ok, image_path} | acc], on_progress)

      {:error, _reason} ->
        Enum.reverse(acc)
    end
  end

  defp convert_single_page(pdf_path, page_num) do
    case PDF2Image.convert(pdf_path, resolution: 150, page: page_num) do
      {:ok, image} ->
        # Save Vix image to temporary file
        tmp_file =
          Path.join(
            System.tmp_dir!(),
            "ocr_page_#{page_num}_#{System.unique_integer([:positive])}.png"
          )

        case Vix.Vips.Image.write_to_file(image, tmp_file) do
          :ok ->
            log_image_fingerprint(page_num, tmp_file)
            {:ok, tmp_file}

          {:error, reason} ->
            Logger.error("Failed to save page #{page_num}: #{inspect(reason)}")
            {:error, "Failed to save page #{page_num}"}
        end

      {:error, reason} ->
        Logger.debug("No more pages or failed to convert page #{page_num}: #{inspect(reason)}")
        {:error, "Page #{page_num} not available"}
    end
  end

  @doc """
  Process multiple images and combine OCR results.
  """
  def process_images(images, on_progress \\ fn _ -> :ok end) when is_list(images) do
    total_pages = length(images)
    log_duplicate_page_images(images)

    # Process each image one by one and collect results
    results =
      images
      |> Enum.with_index(1)
      |> Enum.map(fn {image_path, page_num} ->
        Logger.info("Processing page #{page_num} for OCR...")
        notify_progress(on_progress, "OCR page #{page_num}/#{total_pages}...")

        case send_image_to_ocr_llm(image_path, page_num) do
          {:ok, text} -> {:ok, page_num, text}
          {:error, error} -> {:error, page_num, error}
        end
      end)

    # Check if any pages succeeded
    successes = Enum.filter(results, fn {status, _, _} -> status == :ok end)

    case successes do
      [] ->
        # All failed
        {_, _, first_error} = hd(results)
        {:error, "OCR failed for all pages: #{first_error}"}

      _ ->
        # Combine all successful results
        combined_text =
          successes
          |> Enum.map(fn {:ok, page_num, text} ->
            "--- Page #{page_num} ---\n\n#{text}"
          end)
          |> Enum.join("\n\n")

        {:ok, combined_text}
    end
  end

  @doc """
  Extract text from a single image file via OCR LLM.
  """
  def extract_text_from_image(image_path, page_num \\ 1) do
    send_image_to_ocr_llm(image_path, page_num)
  end

  defp notify_progress(on_progress, message) do
    on_progress.(message)
  rescue
    _ -> :ok
  end

  defp send_image_to_ocr_llm(image_path, page_num) do
    config = Application.get_env(:scanflow, :ocr_llm)
    endpoint = config[:endpoint]
    model = config[:model]
    token = config[:token]
    max_tokens = config[:max_tokens]

    if is_nil(endpoint) or is_nil(model) do
      Logger.warning("OCR LLM not configured, skipping OCR")
      {:ok, "OCR not configured"}
    else
      # Append /chat/completions to the endpoint URL
      full_url = String.trim_trailing(endpoint, "/") <> "/chat/completions"
      Logger.info("OCR request page=#{page_num} model=#{model} max_tokens=#{max_tokens}")
      do_ocr_request(image_path, full_url, model, token, page_num, max_tokens)
    end
  end

  defp do_ocr_request(image_path, endpoint, model, token, page_num, max_tokens) do
    # Read image and convert to base64
    {:ok, image_data} = File.read(image_path)
    base64_image = Base.encode64(image_data)
    mime_type = get_mime_type(image_path)

    # Build request payload for vLLM/OpenAI compatible API
    payload = %{
      model: model,
      messages: [
        %{
          role: "user",
          content: [
            %{
              type: "text",
              text:
                "Transcribe the image exactly. Output only the text from the image, preserving line breaks where possible. Do not explain anything. Stop after the transcription ends."
            },
            %{
              type: "image_url",
              image_url: %{
                url: "data:#{mime_type};base64,#{base64_image}"
              }
            }
          ]
        }
      ],
      temperature: 0.0
    }
    |> maybe_put_max_tokens(max_tokens)

    payload_json = Jason.encode!(payload)
    maybe_log_raw_payload(page_num, payload_json)

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{token}"}
    ]

    started_at = System.monotonic_time(:millisecond)

    case Finch.build(:post, endpoint, headers, payload_json)
         |> Finch.request(Scanflow.Finch, receive_timeout: 300_000) do
      {:ok, %{status: 200, body: body}} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        log_ocr_response_stats(body, page_num, elapsed_ms)
        parse_ocr_response(body, page_num)

      {:ok, %{status: status, body: body}} ->
        Logger.error("OCR LLM returned status #{status} for page #{page_num}: #{body}")
        {:error, "OCR LLM API error for page #{page_num}: #{status}"}

      {:error, error} ->
        Logger.error("OCR LLM request failed for page #{page_num}: #{inspect(error)}")
        {:error, "Failed to connect to OCR LLM for page #{page_num}"}
    end
  end

  defp parse_ocr_response(body, page_num) do
    case Jason.decode(body) do
      {:ok, response} ->
        # Extract text from OpenAI-compatible response
        text =
          response
          |> get_in(["choices", Access.at(0), "message", "content"])
          |> case do
            nil -> "No text extracted"
            content -> sanitize_ocr_text(content)
          end

        {:ok, text}

      {:error, error} ->
        Logger.error("Failed to parse OCR LLM response for page #{page_num}: #{inspect(error)}")
        {:error, "Invalid response from OCR LLM for page #{page_num}"}
    end
  end

  defp get_mime_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      _ -> "image/png"
    end
  end

  defp sanitize_ocr_text(text) when is_binary(text) do
    text
    |> String.replace(~r/^```(?:text)?\s*/i, "")
    |> String.replace(~r/\s*```\s*$/i, "")
    |> String.replace(~r/^here\s+is\s+(the\s+)?extracted\s+text\s*:?\s*/i, "")
    |> String.trim()
  end

  defp log_image_fingerprint(page_num, image_path) do
    with {:ok, data} <- File.read(image_path),
         {:ok, %{size: size}} <- File.stat(image_path) do
      hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

      Logger.info(
        "OCR extracted page=#{page_num} image=#{image_path} bytes=#{size} sha256=#{hash}"
      )
    end
  end

  defp log_duplicate_page_images(images) do
    hashes =
      images
      |> Enum.with_index(1)
      |> Enum.map(fn {path, page_num} ->
        case File.read(path) do
          {:ok, data} -> {page_num, :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)}
          _ -> {page_num, nil}
        end
      end)

    duplicate_groups =
      hashes
      |> Enum.reject(fn {_page, hash} -> is_nil(hash) end)
      |> Enum.group_by(fn {_page, hash} -> hash end, fn {page, _hash} -> page end)
      |> Enum.filter(fn {_hash, pages} -> length(pages) > 1 end)

    if duplicate_groups != [] do
      Logger.warning("OCR detected duplicate page images #{inspect(duplicate_groups)}")
    end
  end

  defp maybe_log_raw_payload(page_num, payload_json) do
    payload_bytes = byte_size(payload_json)
    Logger.info("OCR payload page=#{page_num} bytes=#{payload_bytes}")

    if System.get_env("OCR_LOG_RAW_PAYLOAD") == "true" do
      path =
        Path.join(
          System.tmp_dir!(),
          "ocr_payload_page_#{page_num}_#{System.unique_integer([:positive])}.json"
        )

      case File.write(path, payload_json) do
        :ok -> Logger.info("OCR raw payload page=#{page_num} written=#{path}")
        {:error, reason} -> Logger.error("OCR raw payload write failed #{inspect(reason)}")
      end
    end
  end

  defp log_ocr_response_stats(body, page_num, elapsed_ms) do
    case Jason.decode(body) do
      {:ok, response} ->
        completion_tokens = get_in(response, ["usage", "completion_tokens"])
        prompt_tokens = get_in(response, ["usage", "prompt_tokens"])
        content = get_in(response, ["choices", Access.at(0), "message", "content"]) || ""

        Logger.info(
          "OCR response page=#{page_num} elapsed_ms=#{elapsed_ms} prompt_tokens=#{inspect(prompt_tokens)} completion_tokens=#{inspect(completion_tokens)} content_chars=#{String.length(content)}"
        )

      _ ->
        Logger.info("OCR response page=#{page_num} elapsed_ms=#{elapsed_ms} body_bytes=#{byte_size(body)}")
    end
  end

  defp maybe_put_max_tokens(payload, max_tokens) when is_integer(max_tokens) and max_tokens > 0 do
    Map.put(payload, :max_tokens, max_tokens)
  end

  defp maybe_put_max_tokens(payload, _max_tokens), do: payload
end
