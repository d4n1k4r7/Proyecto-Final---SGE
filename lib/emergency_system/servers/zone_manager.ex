defmodule EmergencySystem.Servers.ZoneManager do
  @moduledoc """
  GenServer que administra las zonas afectadas, sus sectores y puntos de atención,
  y mantiene las asociaciones de la zona con albergues, necesidades, recursos y reportes.
  """
  use GenServer

  alias EmergencySystem.Core.Zone
  alias EmergencySystem.Core.Zone.{Sector, AttentionPoint}
  alias EmergencySystem.Algorithms.ZoneTraversal
  alias EmergencySystem.Storage.TextStorage

  @storage_file "zones.txt"

  # --- API Cliente ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register_zone(code, name, level, estimated_affected \\ 0) do
    GenServer.call(__MODULE__, {:register_zone, code, name, level, estimated_affected})
  end

  def add_sector(zone_code, sector_code, name, level, estimated_affected \\ 0) do
    GenServer.call(
      __MODULE__,
      {:add_sector, zone_code, sector_code, name, level, estimated_affected}
    )
  end

  def add_attention_point(zone_code, sector_code, point_id, name, affected_people) do
    GenServer.call(
      __MODULE__,
      {:add_point, zone_code, sector_code, point_id, name, affected_people}
    )
  end

  @doc """
  Asocia una entidad (`:shelters`, `:needs`, `:resources` o `:reports`) a una zona.
  Es asíncrona: si la zona o la categoría no existen, se ignora sin afectar al servidor.
  Para validar antes de registrar, usar `zone_exists?/1`.
  """
  def link_entity(zone_code, category, entity_id) do
    GenServer.cast(__MODULE__, {:link_entity, zone_code, category, entity_id})
  end

  @doc "Indica si existe una zona con ese código."
  def zone_exists?(zone_code) do
    GenServer.call(__MODULE__, {:zone_exists?, zone_code})
  end

  def get_zone(zone_code) do
    GenServer.call(__MODULE__, {:get_zone, zone_code})
  end

  @doc "Ids asociados a una zona en una categoría (`:shelters`, `:needs`, `:resources`, `:reports`)."
  def linked_entities(zone_code, category) do
    GenServer.call(__MODULE__, {:linked_entities, zone_code, category})
  end

  def get_zone_status(zone_code) do
    GenServer.call(__MODULE__, {:get_zone_status, zone_code})
  end

  def list_zones do
    GenServer.call(__MODULE__, :list_zones)
  end

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_) do
    {:ok, records} = TextStorage.load_records(@storage_file)
    state = Map.new(records, fn %Zone{code: c} = z -> {c, z} end)
    {:ok, state}
  end

  @impl true
  def handle_call({:register_zone, code, name, level, estimated}, _from, state) do
    code = normalize(code)

    if Map.has_key?(state, code) do
      {:reply, {:error, :zona_duplicada}, state}
    else
      case Zone.new(code, name, level, estimated) do
        {:ok, zone} ->
          new_state = Map.put(state, zone.code, zone)
          persist(new_state)
          {:reply, {:ok, zone}, new_state}

        error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:add_sector, zone_code, sec_code, name, level, estimated}, _from, state) do
    zone_code = normalize(zone_code)

    with {:ok, zone} <- fetch_zone(state, zone_code),
         {:ok, sector} <- Sector.new(normalize(sec_code), name, level, estimated),
         {:ok, updated_zone} <- Zone.add_sector(zone, sector) do
      new_state = Map.put(state, zone_code, updated_zone)
      persist(new_state)
      {:reply, {:ok, updated_zone}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:add_point, zone_code, sec_code, pt_id, name, affected}, _from, state) do
    zone_code = normalize(zone_code)

    with {:ok, zone} <- fetch_zone(state, zone_code),
         {:ok, point} <- AttentionPoint.new(pt_id, name, affected),
         {:ok, updated_zone} <- insert_point_in_sector(zone, normalize(sec_code), point) do
      new_state = Map.put(state, zone_code, updated_zone)
      persist(new_state)
      {:reply, {:ok, updated_zone}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:zone_exists?, zone_code}, _from, state) do
    {:reply, Map.has_key?(state, normalize(zone_code)), state}
  end

  @impl true
  def handle_call({:get_zone, zone_code}, _from, state) do
    {:reply, fetch_zone(state, normalize(zone_code)), state}
  end

  @impl true
  def handle_call({:linked_entities, zone_code, category}, _from, state) do
    reply =
      with {:ok, zone} <- fetch_zone(state, normalize(zone_code)),
           true <- category in Zone.linkable_categories() do
        {:ok, Zone.linked(zone, category)}
      else
        false -> {:error, {:categoria_invalida, category}}
        error -> error
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_zone_status, zone_code}, _from, state) do
    case fetch_zone(state, normalize(zone_code)) do
      {:ok, zone} ->
        stats = ZoneTraversal.calculate_zone_stats(zone)

        {:reply,
         {:ok, %{zone: zone, accumulated_stats: stats, links: Zone.link_counts(zone)}}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:list_zones, _from, state) do
    {:reply, Map.values(state), state}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    persist(%{})
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_cast({:link_entity, zone_code, category, entity_id}, state) do
    zone_code = normalize(zone_code)

    with %Zone{} = zone <- Map.get(state, zone_code),
         {:ok, updated} <- Zone.link_entity(zone, category, entity_id) do
      new_state = Map.put(state, zone_code, updated)
      persist(new_state)
      {:noreply, new_state}
    else
      # Zona inexistente o datos inválidos: se ignora para no tumbar el servidor.
      _ -> {:noreply, state}
    end
  end

  # --- Privadas ---

  defp normalize(code) when is_binary(code), do: String.trim(code)
  defp normalize(other), do: other

  defp fetch_zone(state, code) do
    case Map.get(state, code) do
      nil -> {:error, :zona_no_encontrada}
      zone -> {:ok, zone}
    end
  end

  defp insert_point_in_sector(%Zone{sectors: sectors} = zone, sec_code, point) do
    case Enum.find(sectors, &(&1.code == sec_code)) do
      nil ->
        {:error, :sector_no_encontrado}

      %Sector{attention_points: pts} = sec ->
        if Enum.any?(pts, &(&1.id == point.id)) do
          {:error, :punto_atencion_duplicado}
        else
          updated_sec = %{sec | attention_points: [point | pts]}

          updated_sectors =
            Enum.map(sectors, fn s -> if s.code == sec_code, do: updated_sec, else: s end)

          {:ok, %{zone | sectors: updated_sectors}}
        end
    end
  end

  defp persist(state) do
    TextStorage.save_records(@storage_file, Map.values(state))
  end
end
