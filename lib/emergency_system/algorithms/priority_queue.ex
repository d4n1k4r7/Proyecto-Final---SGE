defmodule EmergencySystem.Algorithms.PriorityQueue do
  @moduledoc """
  Ordenamiento, selección y filtrado recursivo de necesidades según nivel de prioridad.
  """

  alias EmergencySystem.Core.Need

  @doc """
  FUNCIÓN RECURSIVA #2:
  Inserta una necesidad de forma ordenada (Insertion Sort recursivo) dentro de una
  lista de necesidades de mayor a menor prioridad (:critica > :alta > :media > :baja).
  """
  def sort_by_priority(needs_list) when is_list(needs_list) do
    do_sort(needs_list, [])
  end

  defp do_sort([], sorted_acc), do: sorted_acc

  defp do_sort([head | tail], sorted_acc) do
    new_sorted = insert_ordered(head, sorted_acc)
    do_sort(tail, new_sorted)
  end

  # Inserción recursiva ordenada por peso de prioridad
  defp insert_ordered(%Need{} = need, []), do: [need]

  defp insert_ordered(%Need{} = need, [%Need{} = current | rest]) do
    if Need.priority_weight(need.priority) >= Need.priority_weight(current.priority) do
      [need, current | rest]
    else
      [current | insert_ordered(need, rest)]
    end
  end

  @doc """
  Selecciona recursivamente la solicitud pendiente de mayor prioridad para ser atendida.
  """
  def next_to_attend(needs_list) when is_list(needs_list) do
    case select_highest_recursive(needs_list, nil) do
      nil -> {:error, :sin_necesidades_pendientes}
      %Need{} = best -> {:ok, best}
    end
  end

  defp select_highest_recursive([], best), do: best

  defp select_highest_recursive([%Need{status: st} = candidate | rest], nil)
       when st in [:pendiente, :asignada, :en_atencion] do
    select_highest_recursive(rest, candidate)
  end

  defp select_highest_recursive([%Need{status: st} = candidate | rest], %Need{} = current_best)
       when st in [:pendiente, :asignada, :en_atencion] do
    if Need.priority_weight(candidate.priority) > Need.priority_weight(current_best.priority) do
      select_highest_recursive(rest, candidate)
    else
      select_highest_recursive(rest, current_best)
    end
  end

  defp select_highest_recursive([_closed | rest], best) do
    select_highest_recursive(rest, best)
  end

  @doc """
  Filtra recursivamente una lista de necesidades según un mapa o keyword list de criterios
  (ej: [zone: "centro", priority: :critica, status: :pendiente, type: :agua]).
  """
  def filter_needs(needs_list, criteria) when is_list(needs_list) do
    do_filter(needs_list, criteria, [])
  end

  defp do_filter([], _criteria, acc), do: sort_by_priority(acc)

  defp do_filter([%Need{} = need | tail], criteria, acc) do
    if matches_all_criteria?(need, Enum.to_list(criteria)) do
      do_filter(tail, criteria, [need | acc])
    else
      do_filter(tail, criteria, acc)
    end
  end

  # Evaluación recursiva de cada criterio de búsqueda
  defp matches_all_criteria?(_need, []), do: true

  defp matches_all_criteria?(%Need{zone: z} = need, [{:zone, val} | rest]) do
    String.downcase(z) == String.downcase(to_string(val)) and matches_all_criteria?(need, rest)
  end

  defp matches_all_criteria?(%Need{priority: p} = need, [{:priority, val} | rest]) do
    p == val and matches_all_criteria?(need, rest)
  end

  defp matches_all_criteria?(%Need{status: s} = need, [{:status, val} | rest]) do
    s == val and matches_all_criteria?(need, rest)
  end

  defp matches_all_criteria?(%Need{type: t} = need, [{:type, val} | rest]) do
    t == val and matches_all_criteria?(need, rest)
  end

  defp matches_all_criteria?(need, [_unknown | rest]), do: matches_all_criteria?(need, rest)
end
