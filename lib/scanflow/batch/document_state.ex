defmodule Scanflow.Batch.DocumentState do
  use GenServer

  alias Scanflow.Batch.Document

  def start_link(%Document{id: id} = doc) do
    GenServer.start_link(__MODULE__, doc, name: via(id))
  end

  def via(id), do: {:via, Registry, {Scanflow.Batch.DocumentRegistry, id}}

  def get(id), do: GenServer.call(via(id), :get)

  def update(id, updater), do: GenServer.cast(via(id), {:update, updater})

  @impl true
  def init(doc) do
    state = touch(doc)
    broadcast(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:update, updater}, state) do
    updated =
      case updater do
        fun when is_function(fun, 1) -> fun.(state)
        attrs when is_map(attrs) -> struct(state, attrs)
      end
      |> touch()

    broadcast(updated)
    {:noreply, updated}
  end

  defp touch(doc), do: %{doc | updated_at: DateTime.utc_now()}

  defp broadcast(doc) do
    Phoenix.PubSub.broadcast(
      Scanflow.PubSub,
      Scanflow.Batch.topic(),
      {:document_updated, doc}
    )
  end
end
