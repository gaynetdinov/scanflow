defmodule Scanflow.Automation.SessionManager do
  use GenServer
  require Logger

  alias Scanflow.Automation.{Config, SessionWorker}

  def start_link(_opts),
    do: GenServer.start_link(__MODULE__, %{active_handler: nil}, name: __MODULE__)

  def scan_page(handler, session_key),
    do: GenServer.call(__MODULE__, {:scan_page, handler, session_key}, 240_000)

  def finalize(handler, session_key, opts \\ []),
    do: GenServer.call(__MODULE__, {:finalize, handler, session_key, opts}, 360_000)

  def current_session, do: GenServer.call(__MODULE__, :current_session)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:current_session, _from, state) do
    case state.active_handler do
      nil -> {:reply, nil, state}
      handler -> {:reply, SessionWorker.state(handler), state}
    end
  end

  @impl true
  def handle_call({:scan_page, handler, session_key}, _from, state) do
    Logger.info(
      "SessionManager scan_page handler=#{handler} session_key=#{session_key} active_handler=#{inspect(state.active_handler)}"
    )

    cond do
      is_nil(state.active_handler) ->
        with {:ok, _pid} <- start_session(handler, session_key),
             {:ok, payload} <- SessionWorker.scan_page(handler, session_key) do
          Logger.info(
            "SessionManager started session handler=#{handler} payload=#{inspect(payload)}"
          )

          {:reply, {:ok, payload}, %{state | active_handler: handler}}
        else
          {:error, error} ->
            Logger.error(
              "SessionManager scan_page failed handler=#{handler} error=#{inspect(error)}"
            )

            {:reply, {:error, error}, state}
        end

      state.active_handler == handler ->
        {:reply, SessionWorker.scan_page(handler, session_key), state}

      true ->
        Logger.warning(
          "SessionManager ignored scan: wrong handler=#{handler} expected=#{state.active_handler}"
        )

        {:reply,
         {:ok,
          %{
            status: "ignored_wrong_handler",
            expected_handler: state.active_handler
          }}, state}
    end
  end

  @impl true
  def handle_call({:finalize, handler, session_key, opts}, _from, state) do
    finalize_handler = Config.finalize_handler()
    finalize_handler_double = Config.finalize_double_handler()
    send_email = Keyword.get(opts, :send_email, true)

    Logger.info(
      "SessionManager finalize button=#{handler} session_key=#{session_key} active_handler=#{inspect(state.active_handler)}"
    )

    cond do
      handler != finalize_handler and handler != finalize_handler_double ->
        Logger.warning(
          "SessionManager ignored finalize: wrong finalize button=#{handler} expected=#{finalize_handler} or #{finalize_handler_double}"
        )

        {:reply,
         {:ok,
          %{
            status: "ignored_wrong_finalize_handler",
            expected: finalize_handler,
            expected_double: finalize_handler_double
          }}, state}

      is_nil(state.active_handler) ->
        Logger.info("SessionManager finalize: no active session")
        {:reply, {:ok, %{status: "no_active_session"}}, state}

      true ->
        active_handler = state.active_handler

        result = finalize_with_wait(active_handler, session_key, send_email)

        case result do
          {:ok, _payload} ->
            Logger.info("SessionManager finalize succeeded active_handler=#{active_handler}")
            {:reply, result, %{state | active_handler: nil}}

          _ ->
            Logger.error("SessionManager finalize failed result=#{inspect(result)}")
            {:reply, result, state}
        end
    end
  end

  defp finalize_with_wait(handler, session_key, send_email) do
    timeout_ms = 180_000
    started_at = System.monotonic_time(:millisecond)
    do_finalize_with_wait(handler, session_key, send_email, started_at, timeout_ms)
  end

  defp do_finalize_with_wait(handler, session_key, send_email, started_at, timeout_ms) do
    result = SessionWorker.finalize(handler, session_key, send_email: send_email)

    case result do
      {:ok, %{"status" => "waiting_for_ocr"}} ->
        maybe_wait_and_retry(handler, session_key, send_email, started_at, timeout_ms, result)

      {:ok, %{status: "waiting_for_ocr"}} ->
        maybe_wait_and_retry(handler, session_key, send_email, started_at, timeout_ms, result)

      _ ->
        result
    end
  end

  defp maybe_wait_and_retry(
         handler,
         session_key,
         send_email,
         started_at,
         timeout_ms,
         waiting_result
       ) do
    elapsed = System.monotonic_time(:millisecond) - started_at

    if elapsed >= timeout_ms do
      Logger.warning("SessionManager finalize timed out waiting for OCR completion")
      waiting_result
    else
      Process.sleep(500)
      do_finalize_with_wait(handler, session_key, send_email, started_at, timeout_ms)
    end
  end

  defp start_session(handler, session_key) do
    case DynamicSupervisor.start_child(
           Scanflow.AutomationSessionSupervisor,
           {SessionWorker, handler: handler, session_key: session_key}
         ) do
      {:ok, pid} ->
        Logger.info(
          "SessionManager started worker pid=#{inspect(pid)} handler=#{handler} session_key=#{session_key}"
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("SessionManager reused worker pid=#{inspect(pid)} handler=#{handler}")
        {:ok, pid}

      {:error, error} ->
        {:error, "Failed to start scan session: #{inspect(error)}"}
    end
  end
end
