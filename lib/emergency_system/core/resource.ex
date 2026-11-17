defmodule EmergencySystem.Core.Resource do
  @moduledoc """
  Modela un recurso en un centro de acopio o albergue con historial de movimientos.

  Además de la ubicación física (`:location`, p. ej. "acopio_1"), el recurso puede
  pertenecer a una zona afectada (`:zone`), lo que permite consultar la disponibilidad
  por tipo de recurso y por zona.
  """

  @enforce_keys [:code, :name, :category, :quantity, :unit, :location]
  defstruct [
    :code,
    :name,
    :category,
    :quantity,
    :unit,
    :location,
    zone: nil,
    history: []
  ]

  @type t :: %__MODULE__{
          code: String.t(),
          name: String.t(),
          category: atom(),
          quantity: non_neg_integer(),
          unit: String.t(),
          location: String.t(),
          zone: String.t() | nil,
          history: list({DateTime.t(), atom(), integer(), String.t()})
        }

  # Encabezado para valor por defecto con múltiples cláusulas
  def new(code, name, category, quantity, unit, location, zone \\ nil)

  def new(code, name, category, quantity, unit, location, zone)
      when is_binary(code) and is_binary(name) and is_atom(category) and
             is_integer(quantity) and quantity >= 0 and is_binary(unit) and
             is_binary(location) and (is_nil(zone) or is_binary(zone)) do
    if blank?(code) or blank?(name) or blank?(unit) or blank?(location) do
      {:error, :campos_vacios}
    else
      location = String.trim(location)

      initial_movement =
        {DateTime.utc_now(), :registro_inicial, quantity, "Inventario inicial en #{location}"}

      {:ok,
       %__MODULE__{
         code: String.trim(code),
         name: String.trim(name),
         category: category,
         quantity: quantity,
         unit: String.trim(unit),
         location: location,
         zone: clean_zone(zone),
         history: [initial_movement]
       }}
    end
  end

  def new(_, _, _, quantity, _, _, _) when is_integer(quantity) and quantity < 0,
    do: {:error, :cantidad_negativa}

  def new(_, _, _, _, _, _, _), do: {:error, :datos_recurso_invalidos}

  @doc "Registra una entrada de inventario."
  def add_stock(res, amount, reason \\ "Entrada")

  def add_stock(%__MODULE__{quantity: current, history: hist} = res, amount, reason)
      when is_integer(amount) and amount > 0 do
    movement = {DateTime.utc_now(), :entrada, amount, reason}
    {:ok, %{res | quantity: current + amount, history: [movement | hist]}}
  end

  def add_stock(_, _, _), do: {:error, :cantidad_entrada_invalida}

  @doc "Descuenta inventario garantizando que nunca quede en negativo."
  def consume_stock(%__MODULE__{quantity: current}, amount, _reason)
      when is_integer(amount) and amount > current do
    {:error, {:inventario_insuficiente, disponible: current, solicitado: amount}}
  end

  def consume_stock(%__MODULE__{quantity: current, history: hist} = res, amount, reason)
      when is_integer(amount) and amount > 0 and amount <= current do
    movement = {DateTime.utc_now(), :salida, amount, reason}
    {:ok, %{res | quantity: current - amount, history: [movement | hist]}}
  end

  def consume_stock(_, _, _), do: {:error, :cantidad_salida_invalida}

  # --- Privadas ---

  defp blank?(text), do: String.trim(text) == ""

  defp clean_zone(nil), do: nil

  defp clean_zone(zone) do
    case String.trim(zone) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
