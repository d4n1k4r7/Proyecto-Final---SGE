defmodule EmergencySystem.Servers.NeedManager do
  @moduledoc """
  GenServer que administra solicitudes de ayuda, las ordena recursivamente por prioridad
  y coordina la asignación atómica de recursos con ResourceManager.
  """
  use GenServer

  alias EmergencySystem.Core.Need
  alias EmergencySystem.Algorithms.PriorityQueue
  alias EmergencySystem.Servers.{ResourceManager, ZoneManager}
  alias EmergencySystem.Storage.TextStorage

  @storage_file "needs.txt"

  # --- API Cliente ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register_need(
        id,
        type,
        description,
        quantity,
        zone,
        priority,
        reported_by,
        entity_ref \\ nil
      ) do
    GenServer.call(
      __MODULE__,
      {:register_need, id, type, description, quantity, zone, priority, reported_by, entity_ref}
    )
  end

  def assign_resource(need_id, resource_identifier, amount) do
    GenServer.call(__MODULE__, {:assign_resource, need_id, resource_identifier, amount})
  end

  def update_status(need_id, new_status) do
    GenServer.call(__MODULE__, {:update_status, need_id, new_status})
  end

  def list_needs(criteria \\ []) do
    GenServer.call(__MODULE__, {:list_needs, criteria})
  end

  def pending_needs do
    GenServer.call(__MODULE__, :pending_needs)
  end

  @doc "Selecciona la necesidad pendiente de mayor prioridad para ser atendida primero."
  def next_priority_need do
    GenServer.call(__MODULE__, :next_priority_need)
  end

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_) do
    {:ok, records} = TextStorage.load_records(@storage_file)
    state = Map.new(records, fn %Need{id: id} = n -> {id, n} end)
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:register_need, id, type, desc, qty, zone, prio, reporter, entity_ref},
        _from,
        state
      ) do
    need_id = id || generate_need_id(state)

    if Map.has_key?(state, need_id) do
      {:reply, {:error, :id_necesidad_duplicado}, state}
    else
      case Need.new(need_id, type, desc, qty, zone, prio, reporter, entity_ref) do
        {:ok, need} ->
          new_state = Map.put(state, need_id, need)
          ZoneManager.link_entity(zone, :needs, need_id)
          persist(new_state)
          {:reply, {:ok, need}, new_state}

        error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:assign_resource, need_id, resource_identifier, amount}, _from, state) do
    case Map.get(state, need_id) do
      nil ->
        {:reply, {:error, :necesidad_no_encontrada}, state}

      %Need{status: status} when status in [:atendida, :cancelada] ->
        {:reply, {:error, {:necesidad_ya_cerrada, status}}, state}

      %Need{} = need ->
        # 1. Validamos primero si la necesidad puede recibir esa cantidad
        with {:ok, updated_need} <- Need.apply_resource(need, amount),
             # 2. Reservamos de forma atómica en el ResourceManager
             {:ok, updated_resource} <-
               ResourceManager.allocate_resource(
                 resource_identifier,
                 amount,
                 "Asignado a necesidad #{need_id}"
               ) do
          new_state = Map.put(state, need_id, updated_need)
          persist(new_state)
          {:reply, {:ok, %{need: updated_need, resource: updated_resource}}, new_state}
        else
          error -> {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:update_status, need_id, new_status}, _from, state) do
    case Map.get(state, need_id) do
      nil ->
        {:reply, {:error, :necesidad_no_encontrada}, state}

      %Need{} = need ->
        case Need.transition_status(need, new_status) do
          {:ok, updated} ->
            new_state = Map.put(state, need_id, updated)
            persist(new_state)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:list_needs, criteria}, _from, state) do
    needs =
      state
      |> Map.values()
      |> PriorityQueue.filter_needs(criteria)

    {:reply, needs, state}
  end

  @impl true
  def handle_call(:pending_needs, _from, state) do
    pending =
      state
      |> Map.values()
      |> Enum.filter(&(&1.status in [:pendiente, :asignada, :en_atencion]))
      |> PriorityQueue.sort_by_priority()

    {:reply, pending, state}
  end

  @impl true
  def handle_call(:next_priority_need, _from, state) do
    reply =
      state
      |> Map.values()
      |> PriorityQueue.next_to_attend()

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    persist(%{})
    {:reply, :ok, %{}}
  end

  defp generate_need_id(state) do
    next = map_size(state) + 1
    "N" <> String.pad_leading(Integer.to_string(next), 3, "0")
  end

  defp persist(state) do
    TextStorage.save_records(@storage_file, Map.values(state))
  end
end
