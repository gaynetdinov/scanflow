defmodule Scanflow.Batch.OcrProducer do
  use GenStage

  def start_link(_opts), do: GenStage.start_link(__MODULE__, :ok, name: __MODULE__)

  def enqueue(document), do: GenStage.call(__MODULE__, {:enqueue, document})

  @impl true
  def init(:ok), do: {:producer, %{queue: :queue.new(), demand: 0}}

  @impl true
  def handle_call({:enqueue, document}, _from, state) do
    queue = :queue.in(document, state.queue)
    {events, queue, demand} = dispatch(queue, state.demand, [])
    {:reply, :ok, events, %{state | queue: queue, demand: demand}}
  end

  @impl true
  def handle_demand(incoming_demand, state) when incoming_demand > 0 do
    demand = state.demand + incoming_demand
    {events, queue, demand} = dispatch(state.queue, demand, [])
    {:noreply, events, %{state | queue: queue, demand: demand}}
  end

  defp dispatch(queue, 0, events), do: {Enum.reverse(events), queue, 0}

  defp dispatch(queue, demand, events) do
    case :queue.out(queue) do
      {{:value, event}, queue} -> dispatch(queue, demand - 1, [event | events])
      {:empty, queue} -> {Enum.reverse(events), queue, demand}
    end
  end
end
