defmodule Scanflow.Api do
  @moduledoc """
  Client for the Paperless-ngx API.
  """

  require Logger
  @api_version "version=9"

  @doc """
  Fetch documents from Paperless-ngx.
  """
  def fetch_documents(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 25)

    endpoint = config(:endpoint)
    url = build_url(endpoint, "/api/documents/", page: page, page_size: page_size)

    case make_request(url) do
      {:ok, body} ->
        response = Jason.decode!(body)

        {:ok,
         %{
           count: response["count"] || 0,
           next: parse_page_number(response["next"]),
           previous: parse_page_number(response["previous"]),
           results: Enum.map(response["results"] || [], &parse_document/1)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Search documents with a query string.
  """
  def search_documents(query, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 25)

    endpoint = config(:endpoint)
    url = build_url(endpoint, "/api/documents/", query: query, page: page, page_size: page_size)

    case make_request(url) do
      {:ok, body} ->
        response = Jason.decode!(body)

        {:ok,
         %{
           count: response["count"] || 0,
           next: parse_page_number(response["next"]),
           previous: parse_page_number(response["previous"]),
           results: Enum.map(response["results"] || [], &parse_document/1)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Fetch custom field definitions.
  """
  def fetch_custom_fields do
    endpoint = config(:endpoint)
    url = build_url(endpoint, "/api/custom_fields/")

    case make_request(url) do
      {:ok, body} ->
        response = Jason.decode!(body)
        {:ok, response["results"] || []}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Resolve custom field id for the `ai_processed` field.
  """
  def ai_processed_field_id do
    ensure_custom_field_id("ai_processed", "boolean")
  end

  @doc """
  Ensure `ai_processed` custom field exists and return its id.
  """
  def ensure_ai_processed_field_id do
    ensure_custom_field_id("ai_processed", "boolean")
  end

  @doc """
  Ensure a custom field exists by name and data type and return its id.
  """
  def ensure_custom_field_id(name, data_type) when is_binary(name) and is_binary(data_type) do
    case find_custom_field_id(name) do
      {:ok, id} ->
        {:ok, id}

      {:error, _} ->
        case create_custom_field(name, data_type) do
          {:ok, id} -> {:ok, id}
          {:error, _} -> find_custom_field_id(name)
        end
    end
  end

  @doc """
  Set ai_processed custom field for a document.
  """
  def set_ai_processed(document_id, value) when is_boolean(value) do
    with {:ok, field_id} <- ensure_ai_processed_field_id(),
         {:ok, doc} <- fetch_document(document_id) do
      merged_custom_fields =
        doc.custom_fields
        |> merge_custom_field(field_id, value)
        |> custom_fields_to_api_list()

      update_document(document_id, %{"custom_fields" => merged_custom_fields})
    end
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

  defp merge_custom_field(custom_fields, field_id, value) do
    custom_fields
    |> normalize_custom_fields()
    |> Map.put(field_id, value)
  end

  defp custom_fields_to_api_list(custom_fields_map) when is_map(custom_fields_map) do
    custom_fields_map
    |> Enum.map(fn {key, value} ->
      %{
        "field" => normalize_field_id(key),
        "value" => value
      }
    end)
  end

  defp normalize_field_id(id) when is_integer(id), do: id

  defp normalize_field_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> id
    end
  end

  defp normalize_field_id(id), do: id

  defp fetch_all_custom_fields do
    endpoint = config(:endpoint)
    do_fetch_all_custom_fields(endpoint, 1, [], 20)
  end

  defp do_fetch_all_custom_fields(_endpoint, page, acc, max_pages) when page > max_pages do
    {:ok, acc}
  end

  defp do_fetch_all_custom_fields(endpoint, page, acc, max_pages) do
    url = build_url(endpoint, "/api/custom_fields/", page: page, page_size: 100)

    case make_request(url) do
      {:ok, body} ->
        response = Jason.decode!(body)
        page_fields = response["results"] || []
        next_page = parse_page_number(response["next"])

        if next_page do
          do_fetch_all_custom_fields(endpoint, next_page, acc ++ page_fields, max_pages)
        else
          {:ok, acc ++ page_fields}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp find_custom_field_id(name) do
    with {:ok, fields} <- fetch_all_custom_fields() do
      fields
      |> Enum.find(fn field ->
        String.downcase(to_string(field["name"] || "")) == String.downcase(name)
      end)
      |> case do
        %{"id" => id} -> {:ok, id}
        _ -> {:error, "Custom field '#{name}' not found"}
      end
    end
  end

  defp create_custom_field(name, data_type) do
    endpoint = config(:endpoint)
    url = "#{endpoint}/api/custom_fields/"
    token = config(:token)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json; #{@api_version}"}
    ]

    body =
      Jason.encode!(%{
        "name" => name,
        "data_type" => data_type
      })

    case Finch.build(:post, url, headers, body) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        case Jason.decode(response_body) do
          {:ok, %{"id" => id}} -> {:ok, id}
          _ -> {:error, "Custom field '#{name}' creation returned invalid response"}
        end

      {:ok, %{status: 400, body: response_body}} ->
        Logger.warning("Custom field create returned 400: #{response_body}")
        {:error, "Failed to create custom field '#{name}'"}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Custom field create failed with status #{status}: #{response_body}")
        {:error, "Failed to create custom field '#{name}'"}

      {:error, error} ->
        Logger.error("Custom field create request failed: #{inspect(error)}")
        {:error, "Failed to create custom field '#{name}'"}
    end
  end

  @doc """
  Upload a PDF document to Paperless.
  """
  def upload_document(pdf_path, opts \\ []) do
    endpoint = config(:endpoint)
    token = config(:token)
    url = "#{endpoint}/api/documents/post_document/"

    title = Keyword.get(opts, :title, Path.basename(pdf_path, ".pdf"))
    custom_fields = Keyword.get(opts, :custom_fields, [])
    content = Keyword.get(opts, :content)
    tags = Keyword.get(opts, :tags, []) |> normalize_tags_for_upload()
    filename = Path.basename(pdf_path)

    with {:ok, file_binary} <- File.read(pdf_path),
         {content_type, body} <-
           build_multipart_body(
             file_binary,
             filename,
             title,
             custom_fields_for_upload(custom_fields),
             content,
             tags
           ) do
      headers = [
        {"Authorization", "Token #{token}"},
        {"Content-Type", content_type},
        {"Accept", "application/json; #{@api_version}"}
      ]

      case Finch.build(:post, url, headers, body)
           |> Finch.request(Scanflow.Finch, receive_timeout: 120_000) do
        {:ok, %{status: status, body: response_body}} when status in [200, 201, 202] ->
          case Jason.decode(response_body) do
            {:ok, response} -> {:ok, response}
            _ -> {:ok, %{raw: response_body}}
          end

        {:ok, %{status: 400, body: response_body}} ->
          if tags != [] and String.contains?(response_body, "\"tags\"") do
            Logger.warning(
              "Upload rejected tags format; retrying without tags. Response: #{response_body}"
            )

            upload_document(pdf_path,
              title: title,
              custom_fields: custom_fields,
              content: content,
              tags: []
            )
          else
            Logger.error("Upload failed with status 400: #{response_body}")
            {:error, "Upload failed with status 400"}
          end

        {:ok, %{status: status, body: response_body}} ->
          Logger.error("Upload failed with status #{status}: #{response_body}")
          {:error, "Upload failed with status #{status}"}

        {:error, error} ->
          Logger.error("Upload request failed: #{inspect(error)}")
          {:error, "Failed to upload document"}
      end
    else
      {:error, reason} -> {:error, "Failed to read PDF: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetch a task by task_id from Paperless tasks endpoint.
  """
  def fetch_task(task_id) when is_binary(task_id) do
    endpoint = config(:endpoint)
    url = build_url(endpoint, "/api/tasks/", task_id: task_id)

    Logger.info("Fetching Paperless task task_id=#{task_id} url=#{url}")

    case make_request(url) do
      {:ok, body} ->
        Logger.info("Paperless task raw response task_id=#{task_id}: #{body}")
        response = Jason.decode!(body)

        task =
          case response do
            %{"results" => [first | _]} -> first
            %{"results" => []} -> nil
            [first | _] when is_map(first) -> first
            [] -> nil
            %{"task_id" => _} = task_map -> task_map
            _ -> nil
          end

        {:ok, task}

      {:error, error} ->
        Logger.error("Failed to fetch task task_id=#{task_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  def fetch_task(task_id), do: {:error, "Invalid task_id: #{inspect(task_id)}"}

  @doc """
  Wait for task completion and return related document id.
  """
  def wait_for_task_document(task_id, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 1000)
    started_at = System.monotonic_time(:millisecond)

    do_wait_for_task_document(task_id, started_at, timeout_ms, poll_interval_ms)
  end

  defp do_wait_for_task_document(task_id, started_at, timeout_ms, poll_interval_ms) do
    case fetch_task(task_id) do
      {:ok, nil} ->
        Logger.info("Task not visible yet task_id=#{task_id}, polling again")
        maybe_poll_again(task_id, started_at, timeout_ms, poll_interval_ms)

      {:ok, task} ->
        status = task_status(task)
        Logger.info("Task poll task_id=#{task_id} status=#{status}")

        cond do
          status in ["SUCCESS", "COMPLETED", "DONE"] ->
            case task_related_document_id(task) do
              nil -> {:error, "Task succeeded but related document id is missing"}
              doc_id -> {:ok, doc_id}
            end

          status in ["FAILURE", "FAILED", "ERROR"] ->
            {:error, "Task failed"}

          true ->
            maybe_poll_again(task_id, started_at, timeout_ms, poll_interval_ms)
        end

      {:error, error} ->
        Logger.warning("Task polling temporary error task_id=#{task_id} error=#{inspect(error)}")
        maybe_poll_again(task_id, started_at, timeout_ms, poll_interval_ms)
    end
  end

  defp maybe_poll_again(task_id, started_at, timeout_ms, poll_interval_ms) do
    elapsed = System.monotonic_time(:millisecond) - started_at

    if elapsed >= timeout_ms do
      {:error, "Task polling timed out"}
    else
      Process.sleep(poll_interval_ms)
      do_wait_for_task_document(task_id, started_at, timeout_ms, poll_interval_ms)
    end
  end

  defp task_status(task) do
    (task["status"] || task["state"] || "")
    |> to_string()
    |> String.upcase()
  end

  defp task_related_document_id(task) do
    result_map = if is_map(task["result"]), do: task["result"], else: %{}

    candidates = [
      task["related_document"],
      task["related_document_id"],
      result_map["document_id"],
      result_map["document"],
      task["document_id"]
    ]

    candidates
    |> Enum.find_value(&coerce_int/1)
  end

  defp coerce_int(value) when is_integer(value), do: value

  defp coerce_int(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      true ->
        case Regex.run(~r{/documents/(\d+)/?}, value, capture: :all_but_first) do
          [id] -> String.to_integer(id)
          _ -> nil
        end
    end
  end

  defp coerce_int(_), do: nil

  @doc """
  Ask Paperless to email a document to a recipient.
  """
  def send_document_email(document_id, email, opts \\ []) do
    endpoint = config(:endpoint)
    token = config(:token)
    path_template = "/api/documents/{id}/email/"
    url = endpoint <> String.replace(path_template, "{id}", to_string(document_id))

    addresses =
      email
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    form_fields =
      addresses_to_form_fields(addresses)
      |> Kernel.++([{"to", email}, {"email", email}])
      |> maybe_put_form("message", Keyword.get(opts, :message))
      |> maybe_put_form("subject", Keyword.get(opts, :subject))

    body = URI.encode_query(form_fields)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json; #{@api_version}"}
    ]

    case Finch.build(:post, url, headers, body) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: status}} when status in [200, 201, 202, 204] ->
        {:ok, :sent}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Send email failed with status #{status}: #{response_body}")
        {:error, "Send email failed with status #{status}"}

      {:error, error} ->
        Logger.error("Send email request failed: #{inspect(error)}")
        {:error, "Failed to send email"}
    end
  end

  @doc """
  Send plain email via Paperless post office API (without document attachment).
  """
  def send_plain_email(email, subject, message) do
    endpoint = config(:endpoint)
    token = config(:token)
    url = endpoint <> "/api/post_office/"

    form_fields = [
      {"addresses", email},
      {"addresses[]", email},
      {"subject", subject},
      {"message", message}
    ]

    body = URI.encode_query(form_fields)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json; #{@api_version}"}
    ]

    case Finch.build(:post, url, headers, body) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: status}} when status in [200, 201, 202, 204] ->
        {:ok, :sent}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Send plain email failed with status #{status}: #{response_body}")
        {:error, "Send plain email failed with status #{status}"}

      {:error, error} ->
        Logger.error("Send plain email request failed: #{inspect(error)}")
        {:error, "Failed to send plain email"}
    end
  end

  @doc """
  Create share link for a document in Paperless.
  """
  def create_share_link(document_id, opts \\ []) do
    endpoint = config(:endpoint)
    token = config(:token)
    url = endpoint <> "/api/share_links/"

    days = Keyword.get(opts, :days, 7)
    file_version = Keyword.get(opts, :file_version, "archive")

    expiration =
      DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.to_iso8601()

    payload = %{
      "expiration" => expiration,
      "document" => document_id,
      "file_version" => file_version
    }

    headers = [
      {"Authorization", "Token #{token}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json; #{@api_version}"}
    ]

    case Finch.build(:post, url, headers, Jason.encode!(payload))
         |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        case Jason.decode(response_body) do
          {:ok, %{"slug" => slug} = response} ->
            link = endpoint <> "/api/share_links/#{slug}/"
            {:ok, Map.put(response, "url", link)}

          {:ok, response} ->
            {:ok, response}

          {:error, _} ->
            {:error, "Invalid share link response"}
        end

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Create share link failed with status #{status}: #{response_body}")
        {:error, "Create share link failed with status #{status}"}

      {:error, error} ->
        Logger.error("Create share link request failed: #{inspect(error)}")
        {:error, "Failed to create share link"}
    end
  end

  defp maybe_put_form(fields, _key, nil), do: fields
  defp maybe_put_form(fields, key, value), do: fields ++ [{key, to_string(value)}]

  defp addresses_to_form_fields([]), do: []

  defp addresses_to_form_fields(addresses) do
    # Paperless expects a list-like field; repeat keys so Django QueryDict.setlist has values.
    Enum.flat_map(addresses, fn address ->
      [
        {"addresses", address},
        {"addresses[]", address}
      ]
    end)
  end

  defp build_multipart_body(file_binary, filename, title, custom_fields, content, tags) do
    boundary = "----paperlessex-#{System.unique_integer([:positive])}"

    base_fields = [
      {"title", title},
      {"custom_fields", Jason.encode!(custom_fields)}
    ]

    tag_fields =
      (tags || [])
      |> Enum.map(fn tag_id -> {"tags", to_string(tag_id)} end)

    fields = base_fields ++ tag_fields

    fields = if is_binary(content), do: [{"content", content} | fields], else: fields

    fields_io =
      Enum.map(fields, fn {name, value} ->
        [
          "--",
          boundary,
          "\r\n",
          "Content-Disposition: form-data; name=\"",
          name,
          "\"\r\n\r\n",
          to_string(value),
          "\r\n"
        ]
      end)

    file_part = [
      "--",
      boundary,
      "\r\n",
      "Content-Disposition: form-data; name=\"document\"; filename=\"",
      filename,
      "\"\r\n",
      "Content-Type: application/pdf\r\n\r\n",
      file_binary,
      "\r\n"
    ]

    closing = ["--", boundary, "--\r\n"]

    content_type = "multipart/form-data; boundary=#{boundary}"
    body = IO.iodata_to_binary([fields_io, file_part, closing])
    {content_type, body}
  end

  defp custom_fields_for_upload(custom_fields) when is_map(custom_fields), do: custom_fields

  defp custom_fields_for_upload(custom_fields) when is_list(custom_fields) do
    Enum.reduce(custom_fields, %{}, fn
      %{"field" => id, "value" => value}, acc ->
        Map.put(acc, normalize_field_id(id), value)

      %{"custom_field" => id, "value" => value}, acc ->
        Map.put(acc, normalize_field_id(id), value)

      %{field: id, value: value}, acc ->
        Map.put(acc, normalize_field_id(id), value)

      %{custom_field: id, value: value}, acc ->
        Map.put(acc, normalize_field_id(id), value)

      id, acc when is_integer(id) ->
        Map.put(acc, id, true)

      _other, acc ->
        acc
    end)
  end

  defp custom_fields_for_upload(_), do: %{}

  defp normalize_tags_for_upload(tags) when is_list(tags) do
    tags
    |> Enum.map(fn
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int_id, ""} -> int_id
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_tags_for_upload(_), do: []

  @doc """
  Fetch a single document by ID.
  """
  def fetch_document(id) do
    endpoint = config(:endpoint)
    url = build_url(endpoint, "/api/documents/#{id}/")

    case make_request(url) do
      {:ok, body} -> {:ok, parse_document(Jason.decode!(body))}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Fetch all tags from Paperless-ngx.
  """
  def fetch_tags do
    endpoint = config(:endpoint)
    url = build_url(endpoint, "/api/tags/")

    case make_request(url) do
      {:ok, body} ->
        response = Jason.decode!(body)
        # Tags API returns {count: N, results: [...]}
        tags =
          (response["results"] || [])
          |> Enum.map(fn tag -> {tag["id"], tag} end)
          |> Map.new()

        {:ok, tags}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_url(endpoint, path, params \\ []) do
    query =
      params
      |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
      |> Enum.join("&")

    "#{endpoint}#{path}?#{query}"
  end

  defp make_request(url) do
    token = config(:token)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Accept", "application/json; #{@api_version}"}
    ]

    case Finch.build(:get, url, headers) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.error("Paperless API returned status #{status}")
        {:error, "API returned status #{status}"}

      {:error, error} ->
        Logger.error("Paperless API request failed: #{inspect(error)}")
        {:error, "Failed to connect to Paperless API"}
    end
  end

  defp parse_document(document) when is_map(document) do
    %{
      id: document["id"],
      title: document["title"] || "Untitled",
      created: document["created"],
      created_date: document["created_date"],
      modified: document["modified"],
      archive_serial_number: document["archive_serial_number"],
      document_type: document["document_type"],
      correspondent: document["correspondent"],
      storage_path: document["storage_path"],
      tags: document["tags"] || [],
      custom_fields: document["custom_fields"] || %{},
      owner: document["owner"],
      notes_count: document["notes_count"] || 0,
      content: document["content"],
      user_can_change: document["user_can_change"],
      original_file_name: document["original_file_name"],
      archived_file_name: document["archived_file_name"],
      original_checksum: document["original_checksum"],
      archived_checksum: document["archived_checksum"],
      pk: document["pk"],
      added: document["added"],
      search_hit: document["__search_hit__"]
    }
  end

  defp parse_document(_), do: nil

  defp parse_page_number(nil), do: nil
  defp parse_page_number(""), do: nil

  defp parse_page_number(url) when is_binary(url) do
    case URI.parse(url).query do
      nil ->
        nil

      query ->
        URI.query_decoder(query)
        |> Enum.find(fn {k, _} -> k == "page" end)
        |> case do
          {_, page_num} -> String.to_integer(page_num)
          _ -> nil
        end
    end
  end

  @doc """
  Download PDF file for a document.
  """
  def download_pdf(document_id) do
    endpoint = config(:endpoint)
    url = "#{endpoint}/api/documents/#{document_id}/download/"
    token = config(:token)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Accept", "application/json; #{@api_version}"}
    ]

    # Create temporary file
    tmp_file = Path.join(System.tmp_dir!(), "paperless_doc_#{document_id}.pdf")

    case Finch.build(:get, url, headers) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: 200, body: body}} ->
        File.write!(tmp_file, body)
        {:ok, tmp_file}

      {:ok, %{status: status}} ->
        {:error, "Download failed with status #{status}"}

      {:error, error} ->
        {:error, "Download failed: #{inspect(error)}"}
    end
  end

  @doc """
  Download original document file binary and content metadata.
  """
  def download_document_binary(document_id) do
    endpoint = config(:endpoint)
    url = "#{endpoint}/api/documents/#{document_id}/download/"
    token = config(:token)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Accept", "*/*"}
    ]

    case Finch.build(:get, url, headers) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: 200, body: body, headers: response_headers}} ->
        content_type =
          response_headers
          |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-type" end)
          |> case do
            {_k, v} -> v
            nil -> "application/octet-stream"
          end

        disposition =
          response_headers
          |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-disposition" end)
          |> case do
            {_k, v} -> v
            nil -> nil
          end

        {:ok, %{body: body, content_type: content_type, content_disposition: disposition}}

      {:ok, %{status: status}} ->
        {:error, "Download failed with status #{status}"}

      {:error, error} ->
        {:error, "Download failed: #{inspect(error)}"}
    end
  end

  @doc """
  Download document thumbnail image binary.
  """
  def download_document_thumbnail(document_id) do
    endpoint = config(:endpoint)
    token = config(:token)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Accept", "image/*,application/json; #{@api_version}"}
    ]

    thumb_urls = [
      "#{endpoint}/api/documents/#{document_id}/thumb/",
      "#{endpoint}/api/documents/#{document_id}/preview/"
    ]

    try_thumbnail_urls(thumb_urls, headers)
  end

  defp try_thumbnail_urls([], _headers), do: {:error, "Thumbnail endpoint not available"}

  defp try_thumbnail_urls([url | rest], headers) do
    case Finch.build(:get, url, headers) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: 200, body: body, headers: response_headers}} ->
        content_type =
          response_headers
          |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-type" end)
          |> case do
            {_k, v} -> v
            nil -> "image/jpeg"
          end

        {:ok, %{body: body, content_type: content_type}}

      {:ok, %{status: status}} when status in [401, 403, 404, 405] ->
        try_thumbnail_urls(rest, headers)

      {:ok, %{status: status}} ->
        {:error, "Thumbnail failed with status #{status}"}

      {:error, error} ->
        {:error, "Thumbnail failed: #{inspect(error)}"}
    end
  end

  @doc """
  Update document fields (title, content, tags).
  """
  def update_document(document_id, attrs) do
    endpoint = config(:endpoint)
    url = "#{endpoint}/api/documents/#{document_id}/"
    token = config(:token)

    headers = [
      {"Authorization", "Token #{token}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json; #{@api_version}"}
    ]

    body = Jason.encode!(attrs)

    case Finch.build(:patch, url, headers, body) |> Finch.request(Scanflow.Finch) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, parse_document(Jason.decode!(response_body))}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Update failed with status #{status}: #{response_body}")
        {:error, "Update failed with status #{status}"}

      {:error, error} ->
        Logger.error("Update request failed: #{inspect(error)}")
        {:error, "Failed to update document"}
    end
  end

  defp config(key) do
    Application.get_env(:scanflow, :paperless_api)[key]
  end
end
