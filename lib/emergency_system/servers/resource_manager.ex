defmodule EmergencySystem.Servers.ResourceManager do
  @moduledoc """
  GenServer transaccional para administrar inventario de recursos en centros de apoyo.
  Resuelve condiciones de carrera garantizando atomicidad en reservas concurrentes.

  Los recursos pueden asociarse a una zona; en ese caso se valida que la zona exista
  y se enlaza el recurso en `ZoneManager`.
  """
  use GenServer

  alias EmergencySystem.Core.Resource
  alias EmergencySystem.Servers.{ShelterManager, ZoneManager}
  alias EmergencySystem.Storage.TextStorage

  @storage_file "resources.txt"

  # --- API Cliente ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Registra un recurso. `zone` es opcional: si se indica, la zona debe existir.
  """
  def register_resource(code, name, category, quantity, unit, location, zone \\ nil) do
    GenServer.call(
      __MODULE__,
      {:register_resource, code, name, category, quantity, unit, location, zone}
    )
  end

  def add_stock(code, amount, reason \\ "Ingreso de inventario") do
    GenServer.call(__MODULE__, {:add_stock, code, amount, reason})
  end

  @doc """
  Reserva atómicamente una cantidad de un recurso por código o por categoría/nombre.
  Usado para resolver concurrencia cuando múltiples usuarios solicitan al mismo tiempo.

  Si se identifica por categoría o nombre y hay varios recursos que coinciden, se elige
  de forma determinista el de menor código que tenga stock suficiente.
  """
  def allocate_resource(code_or_category, amount, reason) do
    GenServer.call(__MODULE__, {:allocate, code_or_category, amount, reason})
  end

  @doc """
  Transfiere inventario entre ubicaciones. Si no se indica `to_zone`, el destino
  conserva la zona del recurso de origen.
  """
  def transfer_resource(code, from_location, to_location, amount, to_zone \\ nil) do
    GenServer.call(__MODULE__, {:transfer, code, from_location, to_location, amount, to_zone})
  end

  @doc "Lista recursos. Filtros: `category: atom`, `location: string`, `zone: string`."
  def list_resources(filters \\ []) do
    GenServer.call(__MODULE__, {:list_resources, filters})
  end

  @doc """
  Disponibilidad agrupada por tipo de recurso y unidad, con los mismos filtros de
  `list_resources/1` (p. ej. `availability(zone: "Z1")`).
  """
  def availability(filters \\ []) do
    GenServer.call(__MODULE__, {:availability, filters})
  end

  def critical_resources(threshold \\ 20) do
    GenServer.call(__MODULE__, {:critical_resources, threshold})
  end

  def get_resource(code) do
    GenServer.call(__MODULE__, {:get_resource, code})
  end

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_) do
    {:ok, records} = TextStorage.load_records(@storage_file)

    # Los registros guardados antes de existir el campo :zone no lo traen: se completa.
    state =
      Map.new(records, fn %Resource{code: c} = r -> {c, Map.put_new(r, :zone, nil)} end)

    {:ok, state}
  end

  @impl true
  def handle_call({:register_resource, code, name, category, qty, unit, loc, zone}, _from, state) do
    key = normalize(code)
    zone = normalize_zone(zone)

    if Map.has_key?(state, key) do
      {:reply, {:error, :codigo_recurso_duplicado}, state}
    else
      with :ok <- validate_zone(zone),
           {:ok, resource} <- Resource.new(key, name, category, qty, unit, loc, zone) do
        new_state = Map.put(state, resource.code, resource)
        persist(new_state)
        link_to_zone(resource)
        {:reply, {:ok, resource}, new_state}
      else
        error -> {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:add_stock, code, amount, reason}, _from, state) do
    code = normalize(code)

    with {:ok, res} <- fetch_resource(state, code),
         {:ok, updated} <- Resource.add_stock(res, amount, reason) do
      new_state = Map.put(state, code, updated)
      persist(new_state)
      {:reply, {:ok, updated}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:allocate, identifier, amount, reason}, _from, state) do
    case find_matching_resource(state, identifier, amount) do
      nil ->
        {:reply, {:error, :recurso_no_encontrado}, state}

      %Resource{code: code} = res ->
        case Resource.consume_stock(res, amount, reason) do
          {:ok, updated} ->
            new_state = Map.put(state, code, updated)
            persist(new_state)
            {:reply, {:ok, updated}, new_state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_call({:transfer, code, from_loc, to_loc, amount, to_zone}, _from, state) do
    code = normalize(code)
    from_loc = normalize(from_loc)
    to_loc = normalize(to_loc)
    to_zone = normalize_zone(to_zone)

    with {:ok, source} <- fetch_resource(state, code),
         :ok <- check_origin(source, from_loc),
         :ok <- check_locations(from_loc, to_loc),
         :ok <- validate_zone(to_zone),
         {:ok, updated_source} <-
           Resource.consume_stock(source, amount, "Transferencia hacia #{to_loc}") do
      dest_code = "#{code}_#{to_loc}"
      dest_zone = to_zone || source.zone

      dest_res = build_destination(state, dest_code, source, to_loc, dest_zone, amount, from_loc)

      new_state =
        state
        |> Map.put(code, updated_source)
        |> Map.put(dest_code, dest_res)

      persist(new_state)
      link_to_zone(dest_res)
      {:reply, {:ok, %{from: updated_source, to: dest_res}}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_resources, filters}, _from, state) do
    resources =
      state
      |> Map.values()
      |> filter_resources(filters)

    {:reply, resources, state}
  end

  @impl true
  def handle_call({:availability, filters}, _from, state) do
    summary =
      state
      |> Map.values()
      |> filter_resources(filters)
      |> Enum.group_by(&{&1.category, &1.unit})
      |> Enum.map(fn {{category, unit}, items} ->
        %{
          category: category,
          unit: unit,
          total: items |> Enum.map(& &1.quantity) |> Enum.sum(),
          resources: items |> Enum.map(& &1.code) |> Enum.sort()
        }
      end)
      |> Enum.sort_by(&{&1.category, &1.unit})

    {:reply, summary, state}
  end

  @impl true
  def handle_call({:critical_resources, threshold}, _from, state) do
    critical =
      state
      |> Map.values()
      |> Enum.filter(fn %Resource{quantity: q} -> q <= threshold end)

    {:reply, critical, state}
  end

  @impl true
  def handle_call({:get_resource, code}, _from, state) do
    {:reply, fetch_resource(state, normalize(code)), state}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    persist(%{})
    {:reply, :ok, %{}}
  end

  # --- Privadas ---

  defp normalize(value) when is_binary(value), do: String.trim(value)
  defp normalize(other), do: other

  defp normalize_zone(zone) when is_binary(zone) do
    case String.trim(zone) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_zone(other), do: other

  defp fetch_resource(state, code) do
    case Map.get(state, code) do
      nil -> {:error, :recurso_no_encontrado}
      %Resource{} = res -> {:ok, res}
    end
  end

  defp validate_zone(nil), do: :ok

  defp validate_zone(zone) when is_binary(zone) do
    if ZoneManager.zone_exists?(zone), do: :ok, else: {:error, :zona_no_encontrada}
  end

  defp validate_zone(_), do: {:error, :zona_invalida}

  # Enlaza el recurso con su zona en ZoneManager y, si su ubicación es un albergue, con ShelterManager.
  defp link_to_zone(%Resource{zone: zone, location: loc, code: code}) do
    if is_binary(zone), do: ZoneManager.link_entity(zone, :resources, code)
    if is_binary(loc), do: ShelterManager.link_resource_if_exists(loc, code)
    :ok
  end

  defp check_origin(%Resource{location: loc}, from_loc) when loc == from_loc, do: :ok
  defp check_origin(%Resource{location: loc}, _), do: {:error, {:ubicacion_origen_no_coincide, loc}}

  defp check_locations(from, to) when is_binary(from) and is_binary(to) do
    cond do
      to == "" -> {:error, :ubicacion_destino_invalida}
      from == to -> {:error, :ubicacion_destino_igual_al_origen}
      true -> :ok
    end
  end

  defp check_locations(_, _), do: {:error, :ubicacion_invalida}

  # Crea el recurso destino o le suma la cantidad transferida si ya existe.
  defp build_destination(state, dest_code, source, to_loc, dest_zone, amount, from_loc) do
    case Map.get(state, dest_code) do
      nil ->
        {:ok, created} =
          Resource.new(
            dest_code,
            source.name,
            source.category,
            amount,
            source.unit,
            to_loc,
            dest_zone
          )

        created

      %Resource{} = existing ->
        {:ok, added} = Resource.add_stock(existing, amount, "Transferencia desde #{from_loc}")
        added
    end
  end

  # Permite buscar por código exacto ("R001"), categoría (:agua) o nombre ("agua").
  # Con varios candidatos la elección es determinista: menor código con stock suficiente.
  defp find_matching_resource(state, identifier, amount) when is_binary(identifier) do
    identifier = String.trim(identifier)

    case Map.get(state, identifier) do
      %Resource{} = exact ->
        exact

      nil ->
        down = String.downcase(identifier)

        state
        |> Map.values()
        |> Enum.filter(fn %Resource{name: n, category: c} ->
          String.downcase(n) == down or Atom.to_string(c) == down
        end)
        |> pick_candidate(amount)
    end
  end

  defp find_matching_resource(state, category, amount) when is_atom(category) do
    state
    |> Map.values()
    |> Enum.filter(fn %Resource{category: c} -> c == category end)
    |> pick_candidate(amount)
  end

  defp find_matching_resource(_state, _identifier, _amount), do: nil

  defp pick_candidate([], _amount), do: nil

  defp pick_candidate(candidates, amount) do
    sorted = Enum.sort_by(candidates, & &1.code)

    Enum.find(sorted, fn r -> is_integer(amount) and r.quantity >= amount end) ||
      Enum.max_by(sorted, & &1.quantity)
  end

  defp filter_resources(list, []), do: list

  defp filter_resources(list, [{:category, cat} | rest]) do
    list
    |> Enum.filter(&(&1.category == cat))
    |> filter_resources(rest)
  end

  defp filter_resources(list, [{:location, loc} | rest]) do
    down_loc = String.downcase(to_string(loc))

    list
    |> Enum.filter(&(String.downcase(&1.location) == down_loc))
    |> filter_resources(rest)
  end

  defp filter_resources(list, [{:zone, zone} | rest]) do
    down_zone = zone |> to_string() |> String.trim() |> String.downcase()

    list
    |> Enum.filter(&(is_binary(&1.zone) and String.downcase(&1.zone) == down_zone))
    |> filter_resources(rest)
  end

  defp filter_resources(list, [_ | rest]), do: filter_resources(list, rest)

  defp persist(state) do
    TextStorage.save_records(@storage_file, Map.values(state))
  end
end
