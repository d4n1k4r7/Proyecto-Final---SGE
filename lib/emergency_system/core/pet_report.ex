defmodule EmergencySystem.Core.PetReport do
  @moduledoc """
  Modela reportes de mascotas extraviadas o encontradas durante la emergencia.
  """

  @valid_types [:perdida, :encontrada]
  @valid_statuses [:activa, :posible_coincidencia, :resuelta]
  @valid_sizes [:pequena, :mediana, :grande]

  @enforce_keys [:id, :type, :species, :name, :traits, :color, :size, :zone, :contact]
  defstruct [
    :id,
    :type,
    :species,
    :name,
    :traits,
    :color,
    :size,
    :zone,
    :contact,
    status: :activa,
    matched_with: nil
  ]

  def valid_statuses, do: @valid_statuses

  def new(id, type, species, name, traits, color, size, zone, contact)
      when is_binary(id) and type in @valid_types and is_binary(species) and
             is_binary(name) and is_binary(traits) and is_binary(color) and
             size in @valid_sizes and is_binary(zone) and is_binary(contact) do
    {:ok,
     %__MODULE__{
       id: String.trim(id),
       type: type,
       species: String.downcase(String.trim(species)),
       name: String.trim(name),
       traits: String.downcase(String.trim(traits)),
       color: String.downcase(String.trim(color)),
       size: size,
       zone: String.downcase(String.trim(zone)),
       contact: String.trim(contact),
       status: :activa
     }}
  end

  def new(_, type, _, _, _, _, _, _, _) when type not in @valid_types,
    do: {:error, {:tipo_reporte_invalido, type}}

  def new(_, _, _, _, _, _, size, _, _) when size not in @valid_sizes,
    do: {:error, {:tamano_invalido, size}}

  def new(_, _, _, _, _, _, _, _, _), do: {:error, :datos_mascota_invalidos}

  @doc "Marca el reporte como resuelto e impide doble resolución."
  def resolve(%__MODULE__{status: :resuelta}, _match_id),
    do: {:error, :reporte_ya_resuelto}

  def resolve(%__MODULE__{} = report, match_id) when is_binary(match_id) do
    {:ok, %{report | status: :resuelta, matched_with: match_id}}
  end

  def mark_possible_match(%__MODULE__{status: :resuelta}, _),
    do: {:error, :reporte_ya_resuelto}

  def mark_possible_match(%__MODULE__{} = report, candidate_id) do
    {:ok, %{report | status: :posible_coincidencia, matched_with: candidate_id}}
  end
end
