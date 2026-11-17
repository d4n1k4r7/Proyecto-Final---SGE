defmodule EmergencySystem.Core.ZoneTest do
  # Pruebas puras: no usan GenServers ni escriben en data/.
  use ExUnit.Case, async: true

  alias EmergencySystem.Core.Zone
  alias EmergencySystem.Core.Zone.{Sector, AttentionPoint}

  setup do
    {:ok, zone} = Zone.new("Z1", "Centro", :critico, 50)
    %{zone: zone}
  end

  test "crea zona válida y rechaza nivel inválido o cantidad negativa" do
    assert {:ok, %Zone{code: "Z1"}} = Zone.new(" Z1 ", "Centro", :alto, 0)
    assert {:error, {:nivel_afectacion_invalido, :nulo}} = Zone.new("Z", "N", :nulo, 0)
    assert {:error, :cantidad_negativa} = Zone.new("Z", "N", :alto, -1)
    assert {:error, :campos_vacios} = Zone.new(" ", "N", :alto, 0)
  end

  test "agrega sectores y evita duplicados", %{zone: zone} do
    {:ok, sector} = Sector.new("S1", "Norte", :alto, 10)
    assert {:ok, zone} = Zone.add_sector(zone, sector)
    assert {:error, :sector_duplicado} = Zone.add_sector(zone, sector)
  end

  test "punto de atención rechaza cantidades negativas" do
    assert {:ok, %AttentionPoint{}} = AttentionPoint.new("PA1", "Escuela", 40)
    assert {:error, :cantidad_negativa} = AttentionPoint.new("PA1", "Escuela", -5)
  end

  test "link_entity asocia recursos sin duplicados", %{zone: zone} do
    {:ok, zone} = Zone.link_entity(zone, :resources, "R001")
    {:ok, zone} = Zone.link_entity(zone, :resources, "R001")
    {:ok, zone} = Zone.link_entity(zone, :resources, "R002")
    assert Zone.linked(zone, :resources) == ["R001", "R002"]
    assert Zone.link_counts(zone).resources == 2
  end

  test "link_entity devuelve error con categoría o id inválidos", %{zone: zone} do
    assert {:error, {:categoria_invalida, :otra}} = Zone.link_entity(zone, :otra, "X")
    assert {:error, :datos_vinculo_invalidos} = Zone.link_entity(zone, :needs, 123)
  end
end
