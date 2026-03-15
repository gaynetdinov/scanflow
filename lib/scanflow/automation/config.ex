defmodule Scanflow.Automation.Config do
  def scan_config do
    Application.get_env(:scanflow, :automation, [])
  end

  def scan_device, do: Keyword.get(scan_config(), :scan_device_id)

  def scan_cmd_template,
    do:
      Keyword.get(
        scan_config(),
        :scan_cmd_template,
        "scanimage -d {device} --resolution 300 {mode_args} --format=png --output-file {output}"
      )

  def pdf_merge_cmd_template,
    do: Keyword.get(scan_config(), :pdf_merge_cmd_template, "img2pdf {inputs} -o {output}")

  def finalize_handler, do: Keyword.get(scan_config(), :finalize_handler, "1_single")

  def finalize_double_handler do
    configured = Keyword.get(scan_config(), :finalize_handler_double)

    if is_binary(configured) and String.trim(configured) != "" do
      configured
    else
      single = finalize_handler()

      if String.ends_with?(single, "_single") do
        String.replace_suffix(single, "_single", "_double")
      else
        single <> "_double"
      end
    end
  end

  def mode_map do
    parse_map(Keyword.get(scan_config(), :scan_mode_map, "single:bw,double:color"))
  end

  def mode_args_map do
    parse_map(
      Keyword.get(scan_config(), :scan_mode_args_map, "bw:--mode Gray,color:--mode Color")
    )
  end

  def handler_email_map do
    parse_map(Keyword.get(scan_config(), :handler_email_map, ""))
  end

  def email_attachment_max_bytes,
    do: Keyword.get(scan_config(), :email_attachment_max_bytes, 10 * 1024 * 1024)

  defp parse_map(value) when is_map(value), do: value

  defp parse_map(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn entry, acc ->
      case String.split(entry, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp parse_map(_), do: %{}
end
