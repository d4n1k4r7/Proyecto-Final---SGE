defmodule EmergencySystem.Servers.ZoneResourceTest do
  use ExUnit.Case, async: false

  alias EmergencySystem.Servers.{ResourceManager, ZoneManager}
  alias EmergencySystem.Storage.TextStorage

  setup do
    EmergencySystem.reset_all()
    {:ok, _} = ZoneManager.register_zone("centro", "Zona Centro", :critico, 100)
    {:ok, _} = ZoneManager.register_zone("norte", "Zona Norte", :alto, 50)
    :ok
  end

  describe "ZoneManager" do
    test "normaliza códigos y rechaza zonas duplicadas" do
      assert {:ok, %{code: "Z9"}} = ZoneManager.register_zone(" Z9 ", "Nueva", :bajo, 0)
      assert ZoneManager.zone_exists?("Z9")
      assert {:error, :zona_duplicada} = ZoneManager.register_zone("Z9", "Otra", :bajo, 0)
      refute ZoneManager.zone_exists?("no_existe")
    end

    test "valida sectores y puntos de atención" do
      assert {:ok, _} = ZoneManager.add_sector("centro", "S1", "Sector 1", :alto, 10)
      assert {:error, :sector_duplicado} = ZoneManager.add_sector("centro", "S1", "Otro", :alto, 10)
      assert {:error, :zona_no_encontrada} = ZoneManager.add_sector("nada", "S1", "X", :alto, 1)

      assert {:ok, _} = ZoneManager.add_attention_point("centro", "S1", "PA1", "Escuela", 40)

      assert {:error, :punto_atencion_duplicado} =
               ZoneManager.add_attention_point("centro", "S1", "PA1", "Escuela", 40)

      assert {:error, :sector_no_encontrado} =
               ZoneManager.add_attention_point("centro", "S9", "PA2", "Coliseo", 5)
    end

    test "una asociación inválida no tumba el servidor" do
      pid = Process.whereis(ZoneManager)

      ZoneManager.link_entity("centro", :categoria_falsa, "X")
      ZoneManager.link_entity("zona_inexistente", :resources, "R001")

      assert {:ok, _} = ZoneManager.get_zone("centro")
      assert Process.whereis(ZoneManager) == pid
    end

    test "linked_entities valida la categoría" do
      assert {:ok, []} = ZoneManager.linked_entities("centro", :resources)
      assert {:error, {:categoria_invalida, :otra}} = ZoneManager.linked_entities("centro", :otra)
      assert {:error, :zona_no_encontrada} = ZoneManager.linked_entities("nada", :resources)
    end
  end

  describe "ResourceManager con zonas" do
    test "un recurso con zona queda enlazado en ZoneManager" do
      assert {:ok, res} =
               ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "acopio_1", "centro")

      assert res.zone == "centro"
      eventually(fn -> assert {:ok, ["R001"]} = ZoneManager.linked_entities("centro", :resources) end)

      eventually(fn ->
        assert {:ok, %{links: %{resources: 1}}} = ZoneManager.get_zone_status("centro")
      end)
    end

    test "rechaza zonas inexistentes y no registra el recurso" do
      assert {:error, :zona_no_encontrada} =
               ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "acopio_1", "nada")

      assert ResourceManager.list_resources() == []
    end

    test "sigue funcionando sin zona (compatibilidad con 6 argumentos)" do
      assert {:ok, %{zone: nil}} =
               ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "acopio_1")
    end

    test "consulta de disponibilidad por tipo y zona" do
      {:ok, _} = ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "a1", "centro")
      {:ok, _} = ResourceManager.register_resource("R002", "agua", :agua, 30, "litros", "a2", "norte")
      {:ok, _} = ResourceManager.register_resource("R003", "kits", :medicamentos, 10, "cajas", "a1", "centro")

      assert [
               %{category: :agua, unit: "litros", total: 50, resources: ["R001"]},
               %{category: :medicamentos, unit: "cajas", total: 10, resources: ["R003"]}
             ] = ResourceManager.availability(zone: "centro")

      assert [%{category: :agua, total: 80, resources: ["R001", "R002"]}] =
               ResourceManager.availability(category: :agua)

      assert [%{code: "R002"}] = ResourceManager.list_resources(zone: "NORTE")
      assert [] = ResourceManager.list_resources(zone: "sin_zona")
    end

    test "add_stock suma inventario y valida los datos" do
      {:ok, _} = ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "a1")

      assert {:ok, %{quantity: 60}} = ResourceManager.add_stock("R001", 10)
      assert {:error, :cantidad_entrada_invalida} = ResourceManager.add_stock("R001", 0)
      assert {:error, :recurso_no_encontrado} = ResourceManager.add_stock("R404", 5)
    end
  end

  describe "asignación determinista por categoría o nombre" do
    setup do
      {:ok, _} = ResourceManager.register_resource("R010", "agua", :agua, 100, "litros", "a1")
      {:ok, _} = ResourceManager.register_resource("R002", "agua", :agua, 5, "litros", "a1")
      {:ok, _} = ResourceManager.register_resource("R005", "agua", :agua, 40, "litros", "a1")
      :ok
    end

    test "elige el menor código con stock suficiente" do
      assert {:ok, %{code: "R005", quantity: 15}} = ResourceManager.allocate_resource(:agua, 25, "x")
      # R005 ya no alcanza: pasa al siguiente con stock suficiente
      assert {:ok, %{code: "R010", quantity: 75}} = ResourceManager.allocate_resource("agua", 25, "y")
    end

    test "si ninguno alcanza informa el mayor stock disponible" do
      assert {:error, {:inventario_insuficiente, [disponible: 100, solicitado: 500]}} =
               ResourceManager.allocate_resource(:agua, 500, "z")
    end

    test "el código exacto no hace fallback a otros recursos" do
      assert {:error, {:inventario_insuficiente, [disponible: 5, solicitado: 20]}} =
               ResourceManager.allocate_resource("R002", 20, "w")

      assert {:error, :recurso_no_encontrado} = ResourceManager.allocate_resource("inexistente", 1, "w")
      assert {:error, :recurso_no_encontrado} = ResourceManager.allocate_resource(123, 1, "w")
    end
  end

  describe "transferencias" do
    setup do
      {:ok, _} = ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "acopio_1", "centro")
      :ok
    end

    test "crea el destino heredando la zona de origen" do
      assert {:ok, %{from: from, to: to}} =
               ResourceManager.transfer_resource("R001", "acopio_1", "albergue_1", 20)

      assert from.quantity == 30
      assert to.quantity == 20
      assert to.code == "R001_albergue_1"
      assert to.location == "albergue_1"
      assert to.zone == "centro"
    end

    test "permite indicar otra zona de destino" do
      assert {:ok, %{to: %{zone: "norte"}}} =
               ResourceManager.transfer_resource("R001", "acopio_1", "albergue_1", 20, "norte")
    end

    test "acumula en el destino si ya existe" do
      {:ok, _} = ResourceManager.transfer_resource("R001", "acopio_1", "albergue_1", 10)
      assert {:ok, %{to: %{quantity: 25}}} =
               ResourceManager.transfer_resource("R001", "acopio_1", "albergue_1", 15)
    end

    test "rechaza transferencias inválidas sin modificar el inventario" do
      assert {:error, :ubicacion_destino_igual_al_origen} =
               ResourceManager.transfer_resource("R001", "acopio_1", "acopio_1", 5)

      assert {:error, :ubicacion_destino_invalida} =
               ResourceManager.transfer_resource("R001", "acopio_1", "  ", 5)

      assert {:error, {:ubicacion_origen_no_coincide, "acopio_1"}} =
               ResourceManager.transfer_resource("R001", "otro", "albergue_1", 5)

      assert {:error, :zona_no_encontrada} =
               ResourceManager.transfer_resource("R001", "acopio_1", "albergue_1", 5, "nada")

      assert {:error, {:inventario_insuficiente, _}} =
               ResourceManager.transfer_resource("R001", "acopio_1", "albergue_1", 999)

      assert [%{code: "R001", quantity: 50}] = ResourceManager.list_resources()
    end
  end

  describe "persistencia en texto plano" do
    test "las zonas se guardan en un archivo de texto legible" do
      {:ok, _} = ZoneManager.add_sector("centro", "S1", "Sector Norte", :alto, 10)

      content = File.read!(Path.join(TextStorage.data_dir(), "zones.txt"))
      assert content =~ "# EmergencySystem TextStorage v1"
      assert content =~ "%EmergencySystem.Core.Zone{"
      assert content =~ "Sector Norte"
    end

    test "las zonas y sus recursos enlazados sobreviven al reinicio de ZoneManager" do
      {:ok, _} =
        ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "a1", "centro")

      eventually(fn ->
        assert {:ok, ["R001"]} = ZoneManager.linked_entities("centro", :resources)
      end)

      restart(ZoneManager)

      assert {:ok, ["R001"]} = ZoneManager.linked_entities("centro", :resources)
      assert ZoneManager.zone_exists?("norte")
    end
  end

  # link_entity es asíncrono (cast): se reintenta brevemente hasta que se refleje.
  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, 1), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, attempts - 1)
  end

  # Mata el proceso y espera a que el supervisor lo reinicie. Se usa una sola vez por
  # archivo de prueba para no superar el máximo de reinicios del supervisor (3 en 5 s).
  defp restart(name) do
    old = Process.whereis(name)
    Process.exit(old, :kill)
    wait_for_new_pid(name, old, 100)
  end

  defp wait_for_new_pid(name, _old, 0), do: flunk("#{inspect(name)} no fue reiniciado")

  defp wait_for_new_pid(name, old, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ ->
        Process.sleep(20)
        wait_for_new_pid(name, old, attempts - 1)
    end
  end
end
