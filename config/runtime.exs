import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/scanflow start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :scanflow, ScanflowWeb.Endpoint, server: true
end

paperless_api_endpoint =
  System.get_env("PAPERLESS_API_ENDPOINT") ||
    raise """
    environment variable PAPERLESS_API_ENDPOINT is missing.
    For example: http://localhost:8000
    """

paperless_api_token =
  System.get_env("PAPERLESS_API_TOKEN") ||
    raise """
    environment variable PAPERLESS_API_TOKEN is missing.
    Generate it from Paperless-ngx web UI in My Profile.
    """

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

host = System.get_env("PHX_HOST") || "localhost"
port = String.to_integer(System.get_env("PORT") || "4000")

config :scanflow, ScanflowWeb.Endpoint,
  url: [host: host, port: 443, scheme: "https"],
  http: [
    ip: {0, 0, 0, 0, 0, 0, 0, 0},
    port: port
  ],
  secret_key_base: secret_key_base

config :scanflow, :paperless_api,
  endpoint: paperless_api_endpoint,
  token: paperless_api_token

max_pages = String.to_integer(System.get_env("OCR_MAX_PAGES") || "3")

visual_llm_context_length =
  String.to_integer(System.get_env("VISUAL_LLM_CONTEXT_LENGTH") || "12000")

visual_llm_reserved_tokens =
  String.to_integer(System.get_env("VISUAL_LLM_RESERVED_TOKENS") || "1500")

visual_llm_endpoint = System.get_env("VISUAL_LLM_ENDPOINT")
visual_llm_model =
  System.get_env("VISUAL_LLM_MODEL_NAME") ||
    System.get_env("OCR_LLM_MODEL_NAME") ||
    System.get_env("TEXT_LLM_MODEL_NAME")

visual_llm_token =
  System.get_env("VISUAL_LLM_TOKEN") ||
    System.get_env("OCR_LLM_TOKEN") ||
    System.get_env("TEXT_LLM_TOKEN")

visual_llm_enabled =
  is_binary(visual_llm_endpoint) and String.trim(visual_llm_endpoint) != ""

if visual_llm_enabled do
  # Single VLM mode: one model handles both OCR and suggestions
  config :scanflow, :llm_mode, :visual

  config :scanflow, :visual_llm,
    endpoint: visual_llm_endpoint,
    model: visual_llm_model,
    token: visual_llm_token,
    max_pages: max_pages,
    context_length: visual_llm_context_length,
    reserved_tokens: visual_llm_reserved_tokens

  # Keep existing keys for compatibility with current OCR/Suggestions modules
  config :scanflow, :ocr_llm,
    endpoint: visual_llm_endpoint,
    model: visual_llm_model,
    token: visual_llm_token,
    max_pages: max_pages

  config :scanflow, :text_llm,
    endpoint: visual_llm_endpoint,
    model: visual_llm_model,
    token: visual_llm_token,
    context_length: visual_llm_context_length,
    reserved_tokens: visual_llm_reserved_tokens
else
  # Two-model mode: OCR model for OCR, text model for suggestions
  config :scanflow, :llm_mode, :separate

  config :scanflow, :ocr_llm,
    endpoint: System.get_env("OCR_LLM_ENDPOINT"),
    model: System.get_env("OCR_LLM_MODEL_NAME"),
    token: System.get_env("OCR_LLM_TOKEN"),
    max_pages: max_pages

  config :scanflow, :text_llm,
    endpoint: System.get_env("TEXT_LLM_ENDPOINT"),
    model: System.get_env("TEXT_LLM_MODEL_NAME"),
    token: System.get_env("TEXT_LLM_TOKEN")
end

config :scanflow, :batch,
  prep_max_concurrency: String.to_integer(System.get_env("BATCH_PREP_MAX_CONCURRENCY") || "4"),
  ocr_consumers: String.to_integer(System.get_env("BATCH_OCR_CONSUMERS") || "2"),
  suggestion_consumers: String.to_integer(System.get_env("BATCH_SUGGESTION_CONSUMERS") || "2")

config :scanflow, :automation,
  scan_device_id: System.get_env("SCAN_DEVICE_ID"),
  scan_cmd_template:
    System.get_env("SCAN_CMD_TEMPLATE") ||
      "scanimage -d {device} --resolution 300 {mode_args} --format=png --output-file {output}",
  scan_mode_map: System.get_env("SCAN_MODE_MAP") || "single:bw,double:color",
  scan_mode_args_map: System.get_env("SCAN_MODE_ARGS_MAP") || "bw:--mode Gray,color:--mode Color",
  finalize_handler: System.get_env("SCAN_FINALIZE_HANDLER") || "1_single",
  finalize_handler_double: System.get_env("SCAN_FINALIZE_HANDLER_DOUBLE"),
  pdf_merge_cmd_template:
    System.get_env("PDF_MERGE_CMD_TEMPLATE") || "img2pdf {inputs} -o {output}",
  handler_email_map: System.get_env("HA_HANDLER_EMAIL_MAP") || "",
  email_attachment_max_bytes:
    String.to_integer(System.get_env("EMAIL_ATTACHMENT_MAX_BYTES") || "10485760"),
  suggestion_trigger_tokens:
    String.to_integer(System.get_env("AUTOMATION_SUGGESTION_TRIGGER_TOKENS") || "3000")
