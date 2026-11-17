defmodule EmergencySystem.Servers.PetMatcher do
  @moduledoc """
  GenServer para gestionar reportes de mascotas perdidas/encontradas y calcular coincidencias.
  """
  use GenServer

  alias EmergencySystem.Core.PetReport
  alias EmergencySystem.Algorithms.SimilarityEngine
  alias EmergencySystem.Servers.ZoneManager
  alias EmergencySystem.Storage.TextStorage

  @storage_file "pets.txt"

  # --- API Cliente ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def report_pet(type, species, name, traits, color, size, zone, contact) do
    GenServer.call(
      __MODULE__,
      {:report_pet, type, species, name, traits, color, size, zone, contact}
    )
  end

  def find_matches do
    GenServer.call(__MODULE__, :find_matches)
  end

  def confirm_match(lost_id, found_id) do
    GenServer.call(__MODULE__, {:confirm_match, lost_id, found_id})
  end

  def list_reports(filters \\ []) do
    GenServer.call(__MODULE__, {:list_reports, filters})
  end

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_) do
    {:ok, records} = TextStorage.load_records(@storage_file)
    state = Map.new(records, fn %PetReport{id: id} = r -> {id, r} end)
    {:ok, state}
  end

  @impl true
  def handle_call({:report_pet, type, species, name, traits, color, size, zone, contact}, _from, state) do
    id = "PET" <> String.pad_leading(Integer.to_string(map_size(state) + 1), 3, "0")

    case PetReport.new(id, type, species, name, traits, color, size, zone, contact) do
      {:ok, report} ->
        new_state = Map.put(state, id, report)
        ZoneManager.link_entity(report.zone, :reports, report.id)
        persist(new_state)
        {:reply, {:ok, report}, new_state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:find_matches, _from, state) do
    all_reports = Map.values(state)
    lost = Enum.filter(all_reports, &(&1.type == :perdida and &1.status != :resuelta))
    found = Enum.filter(all_reports, &(&1.type == :encontrada and &1.status != :resuelta))

    matches = SimilarityEngine.find_all_matches(lost, found)
    new_state = mark_candidates(state, matches)
    if new_state != state, do: persist(new_state)

    {:reply, matches, new_state}
  end

  @impl true
  def handle_call({:confirm_match, lost_id, found_id}, _from, state) do
    with {:ok, lost_rep} <- fetch_report(state, lost_id),
         {:ok, found_rep} <- fetch_report(state, found_id),
         {:ok, resolved_lost} <- PetReport.resolve(lost_rep, found_id),
         {:ok, resolved_found} <- PetReport.resolve(found_rep, lost_id) do
      new_state =
        state
        |> Map.put(lost_id, resolved_lost)
        |> Map.put(found_id, resolved_found)

      persist(new_state)
      {:reply, {:ok, %{lost: resolved_lost, found: resolved_found}}, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_reports, filters}, _from, state) do
    reports =
      state
      |> Map.values()
      |> apply_filters(filters)

    {:reply, reports, state}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    persist(%{})
    {:reply, :ok, %{}}
  end

  defp mark_candidates(state, []), do: state

  defp mark_candidates(state, [%{lost_id: lid, found_id: fid} | rest]) do
    updated_state =
      with {:ok, %PetReport{status: :activa} = l} <- fetch_report(state, lid),
           {:ok, %PetReport{status: :activa} = f} <- fetch_report(state, fid),
           {:ok, l_cand} <- PetReport.mark_possible_match(l, fid),
           {:ok, f_cand} <- PetReport.mark_possible_match(f, lid) do
        state
        |> Map.put(lid, l_cand)
        |> Map.put(fid, f_cand)
      else
        _ -> state
      end

    mark_candidates(updated_state, rest)
  end

  defp fetch_report(state, id) do
    case Map.get(state, id) do
      nil -> {:error, {:reporte_no_encontrado, id}}
      rep -> {:ok, rep}
    end
  end

  defp apply_filters(list, []), do: list

  defp apply_filters(list, [{:species, sp} | rest]) do
    list
    |> Enum.filter(&(String.downcase(&1.species) == String.downcase(to_string(sp))))
    |> apply_filters(rest)
  end

  defp apply_filters(list, [{:zone, z} | rest]) do
    list
    |> Enum.filter(&(String.downcase(&1.zone) == String.downcase(to_string(z))))
    |> apply_filters(rest)
  end

  defp apply_filters(list, [{:status, st} | rest]) do
    list
    |> Enum.filter(&(&1.status == st))
    |> apply_filters(rest)
  end

  defp apply_filters(list, [_ | rest]), do: apply_filters(list, rest)

  defp persist(state) do
    TextStorage.save_records(@storage_file, Map.values(state))
  end
end
