defmodule Scanflow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    batch_config = Application.get_env(:scanflow, :batch, [])
    ocr_consumers = Keyword.get(batch_config, :ocr_consumers, 2)
    suggestion_consumers = Keyword.get(batch_config, :suggestion_consumers, 2)

    children = [
      {Finch, name: Scanflow.Finch},
      ScanflowWeb.Telemetry,
      {Phoenix.PubSub, name: Scanflow.PubSub},
      {Registry, keys: :unique, name: Scanflow.Batch.DocumentRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Scanflow.Batch.DocumentStateSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Scanflow.Batch.ConsumerSupervisor},
      {Task.Supervisor, name: Scanflow.BatchPrepTaskSupervisor},
      {Task.Supervisor, name: Scanflow.AutomationTaskSupervisor},
      {Registry, keys: :unique, name: Scanflow.Automation.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Scanflow.AutomationSessionSupervisor},
      Scanflow.Automation.SessionManager,
      Scanflow.Batch.OcrProducer,
      Scanflow.Batch.SuggestionProducer,
      {Task,
       fn ->
         start_batch_consumers(ocr_consumers, suggestion_consumers)
       end},
      ScanflowWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Scanflow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_batch_consumers(ocr_count, suggestion_count) do
    Enum.each(1..ocr_count, fn idx ->
      DynamicSupervisor.start_child(
        Scanflow.Batch.ConsumerSupervisor,
        %{
          id: {:ocr_consumer, idx},
          start: {Scanflow.Batch.OcrConsumer, :start_link, [[name: {:ocr, idx}]]},
          restart: :permanent,
          shutdown: 5000,
          type: :worker
        }
      )
    end)

    Enum.each(1..suggestion_count, fn idx ->
      DynamicSupervisor.start_child(
        Scanflow.Batch.ConsumerSupervisor,
        %{
          id: {:suggestion_consumer, idx},
          start:
            {Scanflow.Batch.SuggestionConsumer, :start_link, [[name: {:suggestion, idx}]]},
          restart: :permanent,
          shutdown: 5000,
          type: :worker
        }
      )
    end)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ScanflowWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
