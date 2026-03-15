defmodule Scanflow.Automation.Scanner do
  alias Scanflow.Automation.Config
  require Logger

  def scan_page(temp_dir, page_num, handler) do
    output_path = Path.join(temp_dir, "page_#{page_num}.png")
    device = Config.scan_device()
    template = Config.scan_cmd_template()

    if is_nil(device) or String.trim(to_string(device)) == "" do
      {:error, "SCAN_DEVICE_ID is not configured"}
    else
      mode_key = if String.ends_with?(handler, "_double"), do: "double", else: "single"
      mode = Map.get(Config.mode_map(), mode_key, "bw")
      mode_args = Map.get(Config.mode_args_map(), mode, "")

      command =
        template
        |> replace("{device}", shell_escape(device))
        |> replace("{output}", shell_escape(output_path))
        |> replace("{handler}", shell_escape(handler))
        |> replace("{mode}", shell_escape(mode))
        |> replace("{mode_args}", mode_args)

      Logger.info(
        "Scanner executing command for handler=#{handler} mode=#{mode} output=#{output_path}"
      )

      case System.cmd("/bin/sh", ["-lc", command], stderr_to_stdout: true) do
        {_output, 0} ->
          if File.exists?(output_path) do
            Logger.info("Scanner page captured output=#{output_path}")
            {:ok, output_path}
          else
            {:error, "Scan command succeeded but no output file found"}
          end

        {output, _code} ->
          {:error, "Scan failed: #{String.trim(output)}"}
      end
    end
  end

  defp replace(template, _key, _value) when not is_binary(template), do: nil
  defp replace(template, key, value), do: String.replace(template, key, to_string(value || ""))

  defp shell_escape(value) do
    value = to_string(value)
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
