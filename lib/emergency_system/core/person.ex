defmodule EmergencySystem.Core.Person do
  @moduledoc """
  Representa una persona afectada y los mensajes familiares asociados.
  """

  @valid_statuses [
    :sin_informacion,
    :reportada,
    :localizada,
    :trasladada,
    :en_albergue,
    :reunificada
  ]

  defmodule FamilyMessage do
    @enforce_keys [:id, :sender, :recipient_doc, :content]
    defstruct [
      :id,
      :sender,
      :recipient_doc,
      :content,
      status: :pendiente,
      timestamp: nil
    ]

    def new(id, sender, recipient_doc, content)
        when is_binary(id) and is_binary(sender) and is_binary(recipient_doc) and
               is_binary(content) do
      if String.trim(content) == "" do
        {:error, :mensaje_vacio}
      else
        {:ok,
         %__MODULE__{
           id: id,
           sender: String.trim(sender),
           recipient_doc: String.trim(recipient_doc),
           content: String.trim(content),
           status: :pendiente,
           timestamp: DateTime.utc_now()
         }}
      end
    end

    def mark_delivered(%__MODULE__{status: :entregado}),
      do: {:error, :mensaje_ya_entregado}

    def mark_delivered(%__MODULE__{} = msg),
      do: {:ok, %{msg | status: :entregado}}
  end

  @enforce_keys [:id, :name, :document, :age, :zone, :status]
  defstruct [
    :id,
    :name,
    :document,
    :age,
    :zone,
    :status,
    status_history: []
  ]

  def new(id, document, name, age, zone, status \\ :reportada)

  def new(id, document, name, age, zone, status)
      when is_binary(id) and is_binary(document) and is_binary(name) and
             is_integer(age) and age >= 0 and is_binary(zone) and status in @valid_statuses do
    initial_entry = {DateTime.utc_now(), status, "Registro inicial en zona #{zone}"}

    {:ok,
     %__MODULE__{
       id: String.trim(id),
       document: String.trim(document),
       name: String.trim(name),
       age: age,
       zone: String.trim(zone),
       status: status,
       status_history: [initial_entry]
     }}
  end

  def new(_, _, _, age, _, _) when is_integer(age) and age < 0,
    do: {:error, :edad_negativa}

  def new(_, _, _, _, _, status) when status not in @valid_statuses,
    do: {:error, {:estado_persona_invalido, status}}

  def new(_, _, _, _, _, _), do: {:error, :datos_persona_invalidos}

  @doc "Actualiza el estado de la persona y guarda la traza en el historial."
  def update_status(person, new_status, new_zone \\ nil)

  def update_status(%__MODULE__{status: same}, same, _note),
    do: {:error, :mismo_estado}

  def update_status(%__MODULE__{status_history: hist} = person, new_status, new_zone)
      when new_status in @valid_statuses do
    updated_zone = new_zone || person.zone
    entry = {DateTime.utc_now(), new_status, "Cambio a #{new_status} en #{updated_zone}"}

    {:ok,
     %{
       person
       | status: new_status,
         zone: updated_zone,
         status_history: [entry | hist]
     }}
  end

  def update_status(_, bad_status, _), do: {:error, {:estado_invalido, bad_status}}
end
