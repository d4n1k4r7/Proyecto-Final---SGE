defmodule EmergencySystem.Core.Shelter do
  @moduledoc """
  Modela un albergue temporal con control estricto de cupos, registro de ocupantes
  y asociación de recursos y necesidades mediante `MapSet`.
  """

  @enforce_keys [:code, :name, :zone, :max_capacity]
  defstruct [
    :code,
    :name,
    :zone,
    :max_capacity,
    current_occupancy: 0,
    occupants: MapSet.new(),
    resources: MapSet.new(),
    needs: MapSet.new()
  ]

  def new(code, name, zone, max_capacity)
      when is_binary(code) and is_binary(name) and is_binary(zone) and
             is_integer(max_capacity) and max_capacity > 0 do
    if String.trim(code) == "" or String.trim(name) == "" or String.trim(zone) == "" do
      {:error, :campos_vacios}
    else
      {:ok,
       %__MODULE__{
         code: String.trim(code),
         name: String.trim(name),
         zone: String.trim(zone),
         max_capacity: max_capacity
       }}
    end
  end

  def new(_, _, _, cap) when is_integer(cap) and cap <= 0,
    do: {:error, :capacidad_debe_ser_positiva}

  def new(_, _, _, _), do: {:error, :datos_albergue_invalidos}

  @doc "Calcula los cupos disponibles."
  def available_spots(%__MODULE__{max_capacity: max, current_occupancy: occ}), do: max - occ

  @doc "Porcentaje de ocupación para reportes de albergues más llenos."
  def occupancy_percentage(%__MODULE__{max_capacity: max, current_occupancy: occ}) do
    Float.round(occ / max * 100.0, 2)
  end

  @doc "Registra el ingreso de una persona verificando sobrecupo y duplicidad."
  def register_entry(%__MODULE__{max_capacity: max, current_occupancy: occ}, _doc)
      when occ >= max do
    {:error, :capacidad_maxima_alcanzada}
  end

  def register_entry(%__MODULE__{occupants: occ_set, current_occupancy: occ} = shelter, doc)
      when is_binary(doc) do
    doc = String.trim(doc)

    cond do
      doc == "" ->
        {:error, :documento_vacio}

      MapSet.member?(occ_set, doc) ->
        {:error, :persona_ya_registrada_en_albergue}

      true ->
        {:ok,
         %{
           shelter
           | occupants: MapSet.put(occ_set, doc),
             current_occupancy: occ + 1
         }}
    end
  end

  def register_entry(_, _), do: {:error, :documento_invalido}

  @doc "Registra la salida de una persona del albergue."
  def register_exit(%__MODULE__{occupants: occ_set, current_occupancy: occ} = shelter, doc)
      when is_binary(doc) do
    doc = String.trim(doc)

    if MapSet.member?(occ_set, doc) do
      {:ok,
       %{
         shelter
         | occupants: MapSet.delete(occ_set, doc),
           current_occupancy: max(0, occ - 1)
       }}
    else
      {:error, :persona_no_encontrada_en_albergue}
    end
  end

  def register_exit(_, _), do: {:error, :documento_invalido}

  @doc "Asocia un recurso al albergue evitando duplicados con MapSet."
  def link_resource(%__MODULE__{resources: res_set} = shelter, resource_code)
      when is_binary(resource_code) do
    trimmed = String.trim(resource_code)

    if trimmed == "" do
      {:error, :codigo_recurso_vacio}
    else
      {:ok, %{shelter | resources: MapSet.put(res_set, trimmed)}}
    end
  end

  def link_resource(_, _), do: {:error, :codigo_recurso_invalido}

  @doc "Asocia una necesidad puntual al albergue evitando duplicados con MapSet."
  def link_need(%__MODULE__{needs: need_set} = shelter, need_id)
      when is_binary(need_id) do
    trimmed = String.trim(need_id)

    if trimmed == "" do
      {:error, :id_necesidad_vacio}
    else
      {:ok, %{shelter | needs: MapSet.put(need_set, trimmed)}}
    end
  end

  def link_need(_, _), do: {:error, :id_necesidad_invalido}
end
