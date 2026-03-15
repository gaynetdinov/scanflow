defmodule Scanflow.Batch.Document do
  @enforce_keys [:id]
  defstruct id: nil,
            title: nil,
            original_file_name: nil,
            current_tags: [],
            current_content: nil,
            content_snapshot_loaded: false,
            pdf_path: nil,
            image_paths: [],
            ocr_text: nil,
            suggested_title: nil,
            suggested_tags: [],
            apply_title_suggestion: true,
            apply_tags_suggestion: true,
            apply_content_suggestion: true,
            status: "queued",
            status_detail: nil,
            error: nil,
            failed_stage: nil,
            paused: false,
            canceled: false,
            applied: false,
            inserted_at: nil,
            updated_at: nil

  def from_paperless(doc) do
    %__MODULE__{
      id: doc.id,
      title: doc.title,
      original_file_name: doc.original_file_name,
      current_tags: doc.tags || [],
      current_content: doc.content,
      content_snapshot_loaded: false,
      status: "queued",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
