defmodule EmergencySystem.Core.ResourceTest do
  # Pruebas puras: no usan GenServers ni escriben en data/.
  use ExUnit.Case, async: true

  alias EmergencySystem.Core.Resource

  test "crea recurso sin zona (compatibilidad con 6 argumentos)" do
    assert {:ok, %Resource{zone: nil, quantity: 50}} =
             Resource.new("R001", "agua", :agua, 50, "litros", "acopio_1")
  end

  test "crea recurso con zona y la limpia de espacios" do
    assert {:ok, %Resource{zone: "Z1"}} =
             Resource.new("R001", "agua", :agua, 50, "litros", "acopio_1", " Z1 ")

    assert {:ok, %Resource{zone: nil}} =
             Resource.new("R002", "agua", :agua, 5, "litros", "acopio_1", "  ")
  end

  test "valida cantidades y campos vacíos" do
    assert {:error, :cantidad_negativa} = Resource.new("R", "a", :agua, -1, "l", "x")
    assert {:error, :campos_vacios} = Resource.new(" ", "a", :agua, 1, "l", "x")
    assert {:error, :datos_recurso_invalidos} = Resource.new("R", "a", :agua, "1", "l", "x")
  end

  test "add_stock suma y registra el movimiento" do
    {:ok, res} = Resource.new("R001", "agua", :agua, 10, "litros", "a")
    assert {:ok, %Resource{quantity: 15, history: [{_, :entrada, 5, _} | _]}} =
             Resource.add_stock(res, 5)

    assert {:error, :cantidad_entrada_invalida} = Resource.add_stock(res, 0)
  end

  test "consume_stock nunca deja el inventario en negativo" do
    {:ok, res} = Resource.new("R001", "agua", :agua, 10, "litros", "a")
    assert {:ok, %Resource{quantity: 4}} = Resource.consume_stock(res, 6, "x")

    assert {:error, {:inventario_insuficiente, disponible: 10, solicitado: 11}} =
             Resource.consume_stock(res, 11, "x")

    assert {:error, :cantidad_salida_invalida} = Resource.consume_stock(res, 0, "x")
  end
end
