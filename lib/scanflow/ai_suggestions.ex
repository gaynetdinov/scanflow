defmodule Scanflow.AiSuggestions do
  @moduledoc """
  AI Suggestions using Text LLM for document title and tag recommendations.
  """

  require Logger

  @doc """
  Get AI suggestions for document title and tags based on OCR text.
  """
  def get_suggestions(ocr_text, existing_tags) when is_map(existing_tags) do
    llm_mode = Application.get_env(:scanflow, :llm_mode, :separate)
    config = Application.get_env(:scanflow, :text_llm)
    endpoint = config[:endpoint]
    model = config[:model]
    token = config[:token]

    if is_nil(endpoint) or is_nil(model) do
      Logger.warning("Text LLM not configured, skipping suggestions")
      {:ok, %{title: nil, tags: []}}
    else
      # Build the prompt with existing tags
      tag_list = Map.values(existing_tags) |> Enum.map(& &1["name"]) |> Enum.join(", ")
      text_for_suggestions = select_text_for_suggestions(ocr_text, llm_mode, config, tag_list)

      full_url = String.trim_trailing(endpoint, "/") <> "/chat/completions"
      do_suggestion_request(text_for_suggestions, tag_list, full_url, model, token)
    end
  end

  defp do_suggestion_request(ocr_text, existing_tags, endpoint, model, token) do
    prompt = build_prompt(ocr_text, existing_tags)

    payload = %{
      model: model,
      messages: [
        %{
          role: "user",
          content: prompt
        }
      ],
      max_tokens: 500,
      temperature: 0.3
    }

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{token}"}
    ]

    case Finch.build(:post, endpoint, headers, Jason.encode!(payload))
         |> Finch.request(Scanflow.Finch, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} ->
        parse_suggestion_response(body)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Text LLM returned status #{status}: #{body}")
        {:error, "Text LLM API error: #{status}"}

      {:error, error} ->
        Logger.error("Text LLM request failed: #{inspect(error)}")
        {:error, "Failed to connect to Text LLM"}
    end
  end

  defp parse_suggestion_response(body) do
    with {:ok, response} <- Jason.decode(body),
         content when is_binary(content) <-
           get_in(response, ["choices", Access.at(0), "message", "content"]),
         {:ok, parsed} <- parse_json_content(content) do
      {:ok,
       %{
         title: parsed["title"],
         tags: parsed["tags"] || []
       }}
    else
      {:error, error} ->
        Logger.error("Failed to parse suggestion response: #{inspect(error)}")
        {:error, "Invalid response from Text LLM"}

      nil ->
        Logger.error("No content in suggestion response")
        {:error, "Empty response from Text LLM"}
    end
  end

  defp parse_json_content(content) do
    # Try to extract JSON from markdown code blocks if present
    json_str =
      case Regex.run(~r/```json\s*(.*?)\s*```/s, content) do
        [_, json] ->
          json

        _ ->
          # Try without json label
          case Regex.run(~r/```\s*(.*?)\s*```/s, content) do
            [_, json] -> json
            _ -> content
          end
      end

    Jason.decode(json_str)
  rescue
    _ -> {:error, "Failed to parse JSON content"}
  end

  defp select_text_for_suggestions(ocr_text, :visual, config, tag_list) do
    context_length = config[:context_length] || 12_000
    reserved_tokens = config[:reserved_tokens] || 1_500
    prompt_overhead_tokens = estimate_tokens(build_prompt("", tag_list))

    available_tokens =
      max(context_length - reserved_tokens - prompt_overhead_tokens, 256)

    limit_ocr_by_page_context(ocr_text, available_tokens)
  end

  defp select_text_for_suggestions(ocr_text, _mode, _config, _tag_list) do
    String.slice(ocr_text, 0, 3000)
  end

  defp limit_ocr_by_page_context(ocr_text, token_budget) when is_binary(ocr_text) do
    page_blocks =
      Regex.split(~r/(?=--- Page \d+ ---\n\n)/, ocr_text, trim: true)

    case page_blocks do
      [] ->
        trim_to_token_budget(ocr_text, token_budget)

      blocks ->
        {selected, _size} =
          Enum.reduce_while(blocks, {[], 0}, fn block, {acc, size} ->
            block_size = estimate_tokens(block)
            new_size = size + block_size

            cond do
              new_size <= token_budget ->
                {:cont, {[block | acc], new_size}}

              acc == [] ->
                # Always include at least one page
                {:halt, {[trim_to_token_budget(block, token_budget)], token_budget}}

              true ->
                {:halt, {acc, size}}
            end
          end)

        selected
        |> Enum.reverse()
        |> Enum.join("\n\n")
    end
  end

  defp build_prompt(ocr_text, existing_tags) do
    """
    Analyze the following document text and suggest:
    1. A concise, descriptive title for the document
    2. Relevant tags from the provided list that best describe what this document is about so that such
    document can be easily searchable using suggested tags.

    IMPORTANT TITLE CONSTRAINTS:
    - Keep the title short.
    - Maximum 80 characters.
    - Prefer 4-10 words.
    - Do not include long explanations, prefixes, or trailing details.

    Available tags: #{existing_tags}
    Tags description:
    * it -> everything about IT (electronics, buying gadgets, IT devices, computers, chargers, etc)
    * deutsch -> everything about learning German language (books, tutorials)
    * hausbau -> everything about building a house (documents, registrations)
    * haus -> everything about maintaining a house (wartung, maintenance, cleaning, etc)
    * citizenship -> everything document about obtaining German citizenship (certificates, language courses, AMT communication)
    * doctors -> everything about contacting doctors, bills from doctors, pills, prescriptions.
    * nika -> everything related to Veronika Gainetdinov (documents, schools, certificates, etc)
    * damir -> everything related to Damir Gainetdinov (passport, documents, visas, work, etc)
    * russia -> any document in Russian or about Russia (medical history, documents, passports, visas)
    * versicherung -> any document about insurance (car, house, health insurances, etc).
    * rechnung -> should be applied to any document that is about requesting money for a service, where IBAN and request for
    money transfter is mentioned as well as any invoice, bill or rechnung.


    Document text:
    #{ocr_text}

    Respond in JSON format only:
    {
      "title": "suggested title",
      "tags": ["tag1", "tag2", "tag3"]
    }

    Only use tags from the provided list. If no existing tags fit well, return an empty tags array.
    """
  end

  defp estimate_tokens(text) when is_binary(text) do
    # Rough estimate for mixed Latin text/tokenization.
    text
    |> String.length()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
  end

  defp trim_to_token_budget(text, token_budget) do
    approx_char_budget = max(token_budget * 4, 1)
    String.slice(text, 0, approx_char_budget)
  end
end
