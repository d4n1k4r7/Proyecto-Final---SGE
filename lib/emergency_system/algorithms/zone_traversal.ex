defmodule EmergencySystem.Algorithms.ZoneTraversal do
  @moduledoc """
  Algoritmos recursivos sobre la estructura jerárquica:
  Zona -> Sectores -> Puntos de Atención.
  """

  alias EmergencySystem.Core.Zone
  alias EmergencySystem.Core.Zone.{Sector, AttentionPoint}

  @doc """
  FUNCIÓN RECURSIVA #1:
  Calcula las estadísticas acumuladas de una zona recorriendo recursivamente
  sus sectores y los puntos de atención dentro de cada sector.
  Retorna un mapa con el total de afectados, total de sectores y puntos activos.
  """
  def calculate_zone_stats(%Zone{estimated_affected: base_affected, sectors: sectors}) do
    {sectors_count, sectors_affected, total_points} = traverse_sectors(sectors, 0, 0, 0)

    %{
      base_zone_affected: base_affected,
      sectors_count: sectors_count,
      sectors_and_points_affected: sectors_affected,
      total_attention_points: total_points,
      total_accumulated_affected: base_affected + sectors_affected
    }
  end

  # Caso base: no hay más sectores por recorrer
  defp traverse_sectors([], count_acc, affected_acc, points_acc) do
    {count_acc, affected_acc, points_acc}
  end

  # Caso recursivo: procesa el sector actual y desciende a sus puntos de atención
  defp traverse_sectors(
         [%Sector{estimated_affected: sec_affected, attention_points: points} | rest_sectors],
         count_acc,
         affected_acc,
         points_acc
       ) do
    {pts_count, pts_affected} = traverse_attention_points(points, 0, 0)

    traverse_sectors(
      rest_sectors,
      count_acc + 1,
      affected_acc + sec_affected + pts_affected,
      points_acc + pts_count
    )
  end

  # Caso base: no hay más puntos de atención en el sector
  defp traverse_attention_points([], count_acc, affected_acc) do
    {count_acc, affected_acc}
  end

  # Caso recursivo: punto de atención activo suma sus afectados
  defp traverse_attention_points(
         [%AttentionPoint{active: true, affected_people: ppl} | rest_points],
         count_acc,
         affected_acc
       ) do
    traverse_attention_points(rest_points, count_acc + 1, affected_acc + ppl)
  end

  # Caso recursivo: punto de atención inactivo se ignora en el conteo activo
  defp traverse_attention_points([%AttentionPoint{active: false} | rest_points], count_acc, affected_acc) do
    traverse_attention_points(rest_points, count_acc, affected_acc)
  end
end
