defmodule EmergencySystem.Core.Zone do
  @moduledoc """
  Modela la estructura jerárquica: Zona -> Sectores -> Puntos de Atención.
  Usa MapSet para garantizar asociaciones únicas de albergues, necesidades y recursos.
  """

  @valid_levels [:critico, :alto, :medio, :bajo]
  @linkable [:shelters, :needs, :resources, :reports]

  defmodule AttentionPoint do
    @enforce_keys [:id, :name, :affected_people]
    defstruct [:id, :name, affected_people: 0, active: true]

    def new(id, name, affected_people)
        when is_binary(id) and is_binary(name) and is_integer(affected_people) and
               affected_people >= 0 do
      {:ok, %__MODULE__{id: id, name: name, affected_people: affected_people}}
    end

    def new(_, _, affected) when is_integer(affected) and affected < 0,
      do: {:error, :cantidad_negativa}

    def new(_, _, _), do: {:error, :datos_punto_atencion_invalidos}
  end

  defmodule Sector do
    @enforce_keys [:code, :name, :impact_level]
    defstruct [
      :code,
      :name,
      :impact_level,
      estimated_affected: 0,
      attention_points: []
    ]

    # Encabezado para valor por defecto con múltiples cláusulas
    def new(code, name, level, estimated_affected \\ 0)

    def new(code, name, level, estimated_affected)
        when is_binary(code) and is_binary(name) and
               level in [:critico, :alto, :medio, :bajo] and
               is_integer(estimated_affected) and estimated_affected >= 0 do
      {:ok,
       %__MODULE__{
         code: code,
         name: name,
         impact_level: level,
         estimated_affected: estimated_affected,
         attention_points: []
       }}
    end

    def new(_, _, _, affected) when is_integer(affected) and affected < 0,
      do: {:error, :cantidad_negativa}

    def new(_, _, _, _), do: {:error, :datos_sector_invalidos}
  end

  @enforce_keys [:code, :name, :impact_level]
  defstruct [
    :code,
    :name,
    :impact_level,
    estimated_affected: 0,
    sectors: [],
    shelters: MapSet.new(),
    needs: MapSet.new(),
    resources: MapSet.new(),
    reports: MapSet.new()
  ]

  def new(code, name, level, estimated_affected \\ 0)

  def new(code, name, level, estimated_affected)
      when is_binary(code) and is_binary(name) and level in @valid_levels and
             is_integer(estimated_affected) and estimated_affected >= 0 do
    if String.trim(code) == "" or String.trim(name) == "" do
      {:error, :campos_vacios}
    else
      {:ok,
       %__MODULE__{
         code: String.trim(code),
         name: String.trim(name),
         impact_level: level,
         estimated_affected: estimated_affected
       }}
    end
  end

  def new(_, _, level, _) when level not in @valid_levels,
    do: {:error, {:nivel_afectacion_invalido, level}}

  def new(_, _, _, affected) when is_integer(affected) and affected < 0,
    do: {:error, :cantidad_negativa}

  def new(_, _, _, _), do: {:error, :datos_zona_invalidos}

  @doc "Categorías de entidades que se pueden asociar a una zona."
  def linkable_categories, do: @linkable

  @doc "Agrega un sector a la zona evitando códigos duplicados."
  def add_sector(%__MODULE__{sectors: sectors} = zone, %Sector{} = sector) do
    if Enum.any?(sectors, &(&1.code == sector.code)) do
      {:error, :sector_duplicado}
    else
      {:ok, %{zone | sectors: [sector | sectors]}}
    end
  end

  @doc """
  Asocia una entidad (albergue, necesidad, recurso o reporte) usando MapSet.
  Devuelve error (en lugar de lanzar una excepción) si la categoría o el id no son válidos.
  """
  def link_entity(%__MODULE__{} = zone, category, entity_id)
      when category in @linkable and is_binary(entity_id) do
    current_set = Map.fetch!(zone, category)
    {:ok, Map.put(zone, category, MapSet.put(current_set, entity_id))}
  end

  def link_entity(%__MODULE__{}, category, _entity_id) when category not in @linkable,
    do: {:error, {:categoria_invalida, category}}

  def link_entity(_, _, _), do: {:error, :datos_vinculo_invalidos}

  @doc "Lista ordenada de los ids asociados a la zona en una categoría."
  def linked(%__MODULE__{} = zone, category) when category in @linkable do
    zone |> Map.fetch!(category) |> MapSet.to_list() |> Enum.sort()
  end

  @doc "Cantidad de entidades asociadas por categoría."
  def link_counts(%__MODULE__{} = zone) do
    Map.new(@linkable, fn cat -> {cat, zone |> Map.fetch!(cat) |> MapSet.size()} end)
  end
end
