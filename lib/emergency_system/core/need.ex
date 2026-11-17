defmodule EmergencySystem.Core.Need do
  @moduledoc """
  Gestiona solicitudes de ayuda con máquina de estados estricta, pesos de prioridad
  y asociación opcional a persona, familia, albergue o zona.
  """

  @valid_types [
    :agua,
    :alimentos,
    :medicamentos,
    :primeros_auxilios,
    :refugio,
    :transporte,
    :rescate,
    :otra
  ]
  @valid_priorities [:critica, :alta, :media, :baja]
  @valid_statuses [:pendiente, :asignada, :en_atencion, :atendida, :cancelada]

  @enforce_keys [:id, :type, :description, :quantity_required, :zone, :priority, :reported_by]
  defstruct [
    :id,
    :type,
    :description,
    :quantity_required,
    :zone,
    :priority,
    :reported_by,
    entity_ref: nil,
    quantity_assigned: 0,
    status: :pendiente,
    created_at: nil
  ]

  def new(id, type, description, quantity, zone, priority, reported_by, entity_ref \\ nil)

  def new(id, type, description, quantity, zone, priority, reported_by, entity_ref)
      when is_binary(id) and type in @valid_types and is_binary(description) and
             is_integer(quantity) and quantity > 0 and is_binary(zone) and
             priority in @valid_priorities and is_binary(reported_by) and
             (is_nil(entity_ref) or is_binary(entity_ref)) do
    {:ok,
     %__MODULE__{
       id: String.trim(id),
       type: type,
       description: String.trim(description),
       quantity_required: quantity,
       zone: String.trim(zone),
       priority: priority,
       reported_by: String.trim(reported_by),
       entity_ref: clean_ref(entity_ref),
       status: :pendiente,
       created_at: DateTime.utc_now()
     }}
  end

  def new(_, _, _, quantity, _, _, _, _) when is_integer(quantity) and quantity <= 0,
    do: {:error, :cantidad_debe_ser_positiva}

  def new(_, type, _, _, _, _, _, _) when type not in @valid_types,
    do: {:error, {:tipo_necesidad_invalido, type}}

  def new(_, _, _, _, _, priority, _, _) when priority not in @valid_priorities,
    do: {:error, {:prioridad_invalida, priority}}

  def new(_, _, _, _, _, _, _, _), do: {:error, :datos_necesidad_invalidos}

  @doc "Peso numérico de la prioridad para algoritmos de ordenamiento recursivo."
  def priority_weight(:critica), do: 4
  def priority_weight(:alta), do: 3
  def priority_weight(:media), do: 2
  def priority_weight(:baja), do: 1

  @doc "Asigna recursos a la necesidad y actualiza su estado automáticamente."
  def apply_resource(%__MODULE__{status: status}, _amount)
      when status in [:atendida, :cancelada] do
    {:error, {:necesidad_ya_cerrada, status}}
  end

  def apply_resource(%__MODULE__{} = need, amount)
      when is_integer(amount) and amount > 0 do
    new_assigned = need.quantity_assigned + amount

    new_status =
      if new_assigned >= need.quantity_required do
        :atendida
      else
        :asignada
      end

    {:ok, %{need | quantity_assigned: new_assigned, status: new_status}}
  end

  def apply_resource(_, _), do: {:error, :cantidad_invalida}

  @doc "Valida transiciones de estado permitidas."
  def transition_status(%__MODULE__{status: current}, current),
    do: {:error, :mismo_estado}

  def transition_status(%__MODULE__{status: status}, _new_status)
      when status in [:atendida, :cancelada],
      do: {:error, {:transicion_invalida_desde_estado_final, status}}

  def transition_status(%__MODULE__{status: :pendiente} = need, new_status)
      when new_status in [:asignada, :en_atencion, :atendida, :cancelada],
      do: {:ok, %{need | status: new_status}}

  def transition_status(%__MODULE__{status: :asignada} = need, new_status)
      when new_status in [:en_atencion, :atendida, :cancelada],
      do: {:ok, %{need | status: new_status}}

  def transition_status(%__MODULE__{status: :en_atencion} = need, new_status)
      when new_status in [:atendida, :cancelada],
      do: {:ok, %{need | status: new_status}}

  def transition_status(%__MODULE__{status: from}, to) when to in @valid_statuses,
    do: {:error, {:transicion_invalida, from, to}}

  def transition_status(_, _), do: {:error, :estado_desconocido}

  defp clean_ref(nil), do: nil

  defp clean_ref(ref) when is_binary(ref) do
    case String.trim(ref) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
