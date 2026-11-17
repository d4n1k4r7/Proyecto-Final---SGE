defmodule EmergencySystem.Servers.ShelterManager do
  @moduledoc """
  GenServer que gestiona la capacidad, ocupación, entradas/salidas y asociación
  de recursos y necesidades de los albergues.
  """
  use GenServer

  alias EmergencySystem.Core.Shelter
  alias EmergencySystem.Servers.{FamilyRegistry, ZoneManager}
  alias EmergencySystem.Storage.TextStorage

  @storage_file "shelters.txt"

  # --- API Cliente ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register_shelter(code, name, zone, max_capacity) do
    GenServer.call(__MODULE__, {:register_shelter, code, name, zone, max_capacity})
  end

  def check_shelter(code) do
    GenServer.call(__MODULE__, {:check_shelter, code})
  end

  def register_entry(shelter_code, person_doc) do
    GenServer.call(__MODULE__, {:register_entry, shelter_code, person_doc})
  end

  def register_exit(shelter_code, person_doc) do
    GenServer.call(__MODULE__, {:register_exit, shelter_code, person_doc})
  end

  @doc "Asocia un recurso a un albergue registrado."
  def link_resource(shelter_code, resource_code) do
    GenServer.call(__MODULE__, {:link_resource, shelter_code, resource_code})
  end

  @doc "Asocia una necesidad a un albergue registrado."
  def link_need(shelter_code, need_id) do
    GenServer.call(__MODULE__, {:link_need, shelter_code, need_id})
  end

  @doc "Asocia un recurso de forma asíncrona si el código de ubicación corresponde a un albergue."
  def link_resource_if_exists(shelter_code, resource_code) do
    GenServer.cast(__MODULE__, {:link_resource_if_exists, shelter_code, resource_code})
  end

  def top_occupied_shelters do
    GenServer.call(__MODULE__, :top_occupied)
  end

  def list_shelters do
    GenServer.call(__MODULE__, :list_shelters)
  end

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_) do
    {:ok, records} = TextStorage.load_records(@storage_file)
    state = Map.new(records, fn %Shelter{code: c} = s -> {c, s} end)
    {:ok, state}
  end

  @impl true
  def handle_call({:register_shelter, code, name, zone, max_cap}, _from, state) do
    key = normalize(code)

    if Map.has_key?(state, key) do
      {:reply, {:error, :albergue_duplicado}, state}
    else
      case Shelter.new(key, name, zone, max_cap) do
        {:ok, shelter} ->
          new_state = Map.put(state, shelter.code, shelter)
          ZoneManager.link_entity(shelter.zone, :shelters, shelter.code)
          persist(new_state)
          {:reply, {:ok, shelter}, new_state}

        error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:check_shelter, code}, _from, state) do
    case Map.get(state, normalize(code)) do
      nil ->
        {:reply, {:error, :albergue_no_encontrado}, state}

      %Shelter{} = shelter ->
        info = %{
          shelter: shelter,
          available_spots: Shelter.available_spots(shelter),
          occupancy_percentage: Shelter.occupancy_percentage(shelter),
          resources: shelter.resources |> MapSet.to_list() |> Enum.sort(),
          needs: shelter.needs |> MapSet.to_list() |> Enum.sort()
        }

        {:reply, {:ok, info}, state}
    end
  end

  @impl true
  def handle_call({:register_entry, code, doc}, _from, state) do
    key = normalize(code)

    case Map.get(state, key) do
      nil ->
        {:reply, {:error, :albergue_no_encontrado}, state}

      %Shelter{} = shelter ->
        case Shelter.register_entry(shelter, doc) do
          {:ok, updated} ->
            new_state = Map.put(state, key, updated)
            # Si la persona existe en FamilyRegistry, actualizamos su estado a :en_albergue
            _ = FamilyRegistry.update_person_status(doc, :en_albergue, shelter.zone)
            persist(new_state)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:register_exit, code, doc}, _from, state) do
    key = normalize(code)

    case Map.get(state, key) do
      nil ->
        {:reply, {:error, :albergue_no_encontrado}, state}

      %Shelter{} = shelter ->
        case Shelter.register_exit(shelter, doc) do
          {:ok, updated} ->
            new_state = Map.put(state, key, updated)
            _ = FamilyRegistry.update_person_status(doc, :localizada, shelter.zone)
            persist(new_state)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:link_resource, code, resource_code}, _from, state) do
    key = normalize(code)

    case Map.get(state, key) do
      nil ->
        {:reply, {:error, :albergue_no_encontrado}, state}

      %Shelter{} = shelter ->
        case Shelter.link_resource(shelter, resource_code) do
          {:ok, updated} ->
            new_state = Map.put(state, key, updated)
            persist(new_state)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:link_need, code, need_id}, _from, state) do
    key = normalize(code)

    case Map.get(state, key) do
      nil ->
        {:reply, {:error, :albergue_no_encontrado}, state}

      %Shelter{} = shelter ->
        case Shelter.link_need(shelter, need_id) do
          {:ok, updated} ->
            new_state = Map.put(state, key, updated)
            persist(new_state)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call(:top_occupied, _from, state) do
    ranked =
      state
      |> Map.values()
      |> Enum.sort_by(&Shelter.occupancy_percentage/1, :desc)

    {:reply, ranked, state}
  end

  @impl true
  def handle_call(:list_shelters, _from, state) do
    {:reply, Map.values(state), state}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    persist(%{})
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_cast({:link_resource_if_exists, code, resource_code}, state) do
    key = normalize(code)

    with %Shelter{} = shelter <- Map.get(state, key),
         {:ok, updated} <- Shelter.link_resource(shelter, resource_code) do
      new_state = Map.put(state, key, updated)
      persist(new_state)
      {:noreply, new_state}
    else
      _ -> {:noreply, state}
    end
  end

  defp normalize(val) when is_binary(val), do: String.trim(val)
  defp normalize(other), do: other

  defp persist(state) do
    TextStorage.save_records(@storage_file, Map.values(state))
  end
end
