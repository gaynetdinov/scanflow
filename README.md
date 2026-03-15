# Scanflow

Scanflow is a Phoenix LiveView app for browsing, reviewing, and automating document flows from a Paperless-ngx instance.

## What It Does

- Browse and search documents from Paperless-ngx
- Show document metadata (tags, correspondent, type, storage path)
- Run OCR + AI suggestions (visual model mode or split OCR/text model mode)
- Support scanner automation flows (single/double press handlers)
- Deploy with Docker

## Environment Variables

These are the variables you should configure for production use.

### Required (app startup will fail if missing)

- `PAPERLESS_API_ENDPOINT`: Base URL of Paperless-ngx, for example `http://paperless-ngx:8000`
- `PAPERLESS_API_TOKEN`: API token from Paperless-ngx (My Profile)
- `SECRET_KEY_BASE`: Phoenix secret key (`mix phx.gen.secret`)

### Common Runtime Settings

- `PHX_HOST`: Public host name (default: `localhost`)
- `PORT`: App port inside the container (default: `4000`)

### AI/OCR Configuration

Choose one of these modes:

1. Visual model mode (recommended): set all of
   - `VISUAL_LLM_ENDPOINT`
   - `VISUAL_LLM_MODEL_NAME`
   - `VISUAL_LLM_TOKEN`
2. Split model mode: set the OCR and text model groups
   - OCR: `OCR_LLM_ENDPOINT`, `OCR_LLM_MODEL_NAME`, `OCR_LLM_TOKEN`
   - Text: `TEXT_LLM_ENDPOINT`, `TEXT_LLM_MODEL_NAME`, `TEXT_LLM_TOKEN`

Optional tuning:

- `VISUAL_LLM_CONTEXT_LENGTH` (default: `12000`)
- `VISUAL_LLM_RESERVED_TOKENS` (default: `1500`)

### Batch Pipeline (optional)

- `BATCH_PREP_MAX_CONCURRENCY` (default: `4`)
- `BATCH_OCR_CONSUMERS` (default: `2`)
- `BATCH_SUGGESTION_CONSUMERS` (default: `2`)

### Scanner Automation (optional)

- `SCAN_DEVICE_ID`
- `SCAN_CMD_TEMPLATE` (default uses `scanimage`)
- `SCAN_MODE_MAP` (default: `single:bw,double:color`)
- `SCAN_MODE_ARGS_MAP` (default: `bw:--mode Gray,color:--mode Color`)
- `SCAN_FINALIZE_HANDLER` (default: `1_single`)
- `SCAN_FINALIZE_HANDLER_DOUBLE` (default inferred from single handler)
- `PDF_MERGE_CMD_TEMPLATE` (default uses `img2pdf`)
- `AUTOMATION_SUGGESTION_TRIGGER_TOKENS` (default: `3000`)
- `EMAIL_ATTACHMENT_MAX_BYTES` (default: `10485760`)
- `HA_HANDLER_EMAIL_MAP` (example: `2_single:accounting@example.com,3_single:hr@example.com`)

## Docker Quickstart

1. Copy the template file:

```bash
cp docker-compose.yml.example docker-compose.yml
```

2. Edit `docker-compose.yml` and fill in your real values.

3. Start the app:

```bash
docker compose up -d
```

4. Open `http://localhost:4000`.

## Docker Image Notes

The Dockerfile builds and runs Scanflow with Elixir/Erlang available in the container, and also installs runtime tools used by automation/OCR flows:

- `scanimage` (from `sane-utils`)
- `img2pdf`
- `poppler-utils`
- `libvips`

## Local Development

```bash
mix deps.get
mix phx.server
```

## Project Structure

- `lib/scanflow/api.ex` - Paperless-ngx API client
- `lib/scanflow_web/live/documents_live.ex` - main LiveView module
- `lib/scanflow/automation/` - scanner + finalize automation pipeline

## License

MIT
