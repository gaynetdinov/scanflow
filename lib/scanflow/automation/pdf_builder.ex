defmodule Scanflow.Automation.PdfBuilder do
  alias Scanflow.Automation.Config

  def merge_images_to_pdf(image_paths, output_pdf) when is_list(image_paths) do
    inputs = image_paths |> Enum.map(&shell_escape/1) |> Enum.join(" ")

    command =
      Config.pdf_merge_cmd_template()
      |> String.replace("{inputs}", inputs)
      |> String.replace("{output}", shell_escape(output_pdf))

    case System.cmd("/bin/sh", ["-lc", command], stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_pdf) do
          {:ok, output_pdf}
        else
          {:error, "PDF merge command succeeded but output PDF was not found"}
        end

      {output, _code} ->
        {:error, "PDF merge failed: #{String.trim(output)}"}
    end
  end

  defp shell_escape(value) do
    value = to_string(value)
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
