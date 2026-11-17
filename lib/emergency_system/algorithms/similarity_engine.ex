defmodule EmergencySystem.Algorithms.SimilarityEngine do
  @moduledoc """
  Motor recursivo de emparejamiento y puntaje de similitud para mascotas
  perdidas y encontradas.
  """

  alias EmergencySystem.Core.PetReport

  @min_match_score 60

  @doc """
  FUNCIÓN RECURSIVA #3:
  Compara recursivamente todos los reportes de mascotas perdidas activas contra
  los reportes de mascotas encontradas activas, produciendo tuplas con el puntaje
  de similitud cuando supera el umbral mínimo (60 pts).
  """
  def find_all_matches(lost_reports, found_reports)
      when is_list(lost_reports) and is_list(found_reports) do
    do_match_lost(lost_reports, found_reports, [])
  end

  # Caso base exterior: terminamos de recorrer las mascotas perdidas
  defp do_match_lost([], _found_reports, matches_acc), do: matches_acc

  # Solo evaluamos reportes que no estén ya resueltos
  defp do_match_lost([%PetReport{status: :resuelta} | rest_lost], found_reports, matches_acc) do
    do_match_lost(rest_lost, found_reports, matches_acc)
  end

  defp do_match_lost([%PetReport{} = lost | rest_lost], found_reports, matches_acc) do
    candidates = evaluate_against_found(lost, found_reports, [])
    do_match_lost(rest_lost, found_reports, candidates ++ matches_acc)
  end

  # Caso base interior: terminamos de comparar una mascota perdida contra las encontradas
  defp evaluate_against_found(_lost, [], acc), do: acc

  defp evaluate_against_found(lost, [%PetReport{status: :resuelta} | rest_found], acc) do
    evaluate_against_found(lost, rest_found, acc)
  end

  defp evaluate_against_found(%PetReport{} = lost, [%PetReport{} = found | rest_found], acc) do
    score = compute_similarity_score(lost, found)

    if score >= @min_match_score do
      match_entry = %{
        lost_id: lost.id,
        found_id: found.id,
        species: lost.species,
        zone: lost.zone,
        score: score
      }

      evaluate_against_found(lost, rest_found, [match_entry | acc])
    else
      evaluate_against_found(lost, rest_found, acc)
    end
  end

  @doc "Calcula el puntaje de similitud (0 a 100) evaluando atributos recursivamente."
  def compute_similarity_score(%PetReport{species: s1}, %PetReport{species: s2})
      when s1 != s2,
      do: 0

  def compute_similarity_score(%PetReport{} = lost, %PetReport{} = found) do
    attributes_rules = [
      {:species, lost.species == found.species, 35},
      {:zone, lost.zone == found.zone, 25},
      {:color, String.contains?(found.color, lost.color) or String.contains?(lost.color, found.color), 20},
      {:size, lost.size == found.size, 15},
      {:traits_or_name,
       names_match?(lost.name, found.name) or String.contains?(found.traits, lost.traits), 5}
    ]

    sum_attribute_scores(attributes_rules, 0)
  end

  # Suma recursiva de los criterios de evaluación
  defp sum_attribute_scores([], total), do: total
  defp sum_attribute_scores([{_attr, true, points} | rest], total), do: sum_attribute_scores(rest, total + points)
  defp sum_attribute_scores([{_attr, false, _points} | rest], total), do: sum_attribute_scores(rest, total)

  defp names_match?(n1, n2) do
    d1 = String.downcase(n1)
    d2 = String.downcase(n2)
    d1 != "desconocido" and d2 != "desconocido" and d1 == d2
  end
end
