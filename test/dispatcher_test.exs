defmodule EmergencySystem.CLI.DispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    EmergencySystem.reset_all()

    {{:ok, _}, _} = run("connect coord 1234 coordinador centro", nil)
    {{:ok, _}, _} = run("connect volu 1234 voluntario centro", nil)
    {{:ok, _}, _} = run("connect ciud 1234 ciudadano centro", nil)

    %{coord: "coord", volu: "volu", ciud: "ciud"}
  end

  # Ejecuta un comando como lo haría la consola y devuelve {resultado, salida_impresa}.
  defp run(command, user) do
    output =
      capture_io(fn ->
        send(self(), {:result, EmergencySystem.cmd(command, user)})
      end)

    assert_received {:result, {result, _user}}
    {result, output}
  end

  describe "zonas, sectores y puntos de atención" do
    test "registra sector, punto de atención y consulta el estado de la zona", %{coord: coord} do
      {{:ok, _}, _} = run(~s(register_zone centro "Zona Centro" critico), coord)

      {{:ok, _}, out} = run(~s(add_sector centro S1 "Sector Norte" alto 100), coord)
      assert out =~ "Sector S1"

      {{:ok, _}, out} = run(~s(add_attention_point centro S1 PA1 "Escuela" 40), coord)
      assert out =~ "Punto de atención PA1"

      {{:ok, _}, out} = run("zone_status centro", coord)
      assert out =~ "Sectores: 1"
      assert out =~ "Puntos de atención: 1"
      assert out =~ "Afectados acumulados: 140"
    end

    test "el sector acepta el número de afectados como opcional", %{coord: coord} do
      {{:ok, _}, _} = run(~s(register_zone centro "Zona Centro" critico), coord)
      assert {{:ok, _}, _} = run(~s(add_sector centro S1 "Sector Norte" alto), coord)
    end

    test "informa errores de validación", %{coord: coord} do
      {{:ok, _}, _} = run(~s(register_zone centro "Zona Centro" critico), coord)

      assert {{:error, :cantidad_invalida}, _} =
               run(~s(add_sector centro S1 "Sector" alto abc), coord)

      assert {{:error, :zona_no_encontrada}, _} =
               run(~s(add_sector nada S1 "Sector" alto 10), coord)

      assert {{:error, :sector_no_encontrado}, _} =
               run(~s(add_attention_point centro S9 PA1 "Escuela" 40), coord)

      assert {{:error, :zona_no_encontrada}, _} = run("zone_status nada", coord)
    end

    test "respeta los permisos por rol", %{volu: volu, ciud: ciud} do
      assert {{:error, {:no_autorizado, :ciudadano, :register_zone}}, _} =
               run(~s(register_zone centro "Zona Centro" critico), ciud)

      assert {{:error, {:no_autorizado, :voluntario, :add_sector}}, _} =
               run(~s(add_sector centro S1 "Sector" alto 10), volu)

      assert {{:error, {:no_autorizado, :ciudadano, :view_summary}}, _} =
               run("zone_status centro", ciud)
    end
  end

  describe "recursos" do
    setup %{coord: coord} do
      {{:ok, _}, _} = run(~s(register_zone centro "Zona Centro" critico), coord)
      {{:ok, _}, _} = run(~s(register_zone norte "Zona Norte" alto), coord)
      :ok
    end

    test "registra recursos con y sin zona", %{coord: coord} do
      {{:ok, res}, out} = run("register_resource R001 agua 50 litros acopio_1 centro", coord)
      assert res.zone == "centro"
      assert out =~ "Zona: centro"

      assert {{:ok, %{zone: nil}}, out} = run("register_resource R002 agua 30 litros acopio_2", coord)
      assert out =~ "sin zona"
    end

    test "rechaza zonas inexistentes y cantidades inválidas", %{coord: coord} do
      assert {{:error, :zona_no_encontrada}, _} =
               run("register_resource R001 agua 50 litros acopio_1 nada", coord)

      assert {{:error, :cantidad_invalida}, _} =
               run("register_resource R001 agua cincuenta litros acopio_1", coord)
    end

    test "add_stock suma inventario y valida los datos", %{coord: coord} do
      {{:ok, _}, _} = run("register_resource R001 agua 50 litros acopio_1", coord)

      assert {{:ok, %{quantity: 70}}, out} = run("add_stock R001 20", coord)
      assert out =~ "Stock actual: 70"

      assert {{:error, :cantidad_invalida}, _} = run("add_stock R001 abc", coord)
      assert {{:error, :cantidad_invalida}, _} = run("add_stock R001 10x", coord)
      assert {{:error, :recurso_no_encontrado}, _} = run("add_stock R999 5", coord)
    end

    test "solo coordinador y administrador pueden agregar inventario", %{coord: coord, volu: volu} do
      {{:ok, _}, _} = run("register_resource R001 agua 50 litros acopio_1", coord)

      assert {{:error, {:no_autorizado, :voluntario, :add_stock}}, _} =
               run("add_stock R001 5", volu)
    end

    test "list_resources filtra por zona, tipo y ubicación", %{coord: coord} do
      {{:ok, _}, _} = run("register_resource R001 agua 50 litros acopio_1 centro", coord)
      {{:ok, _}, _} = run("register_resource R002 agua 30 litros acopio_2 norte", coord)
      {{:ok, _}, _} = run("register_resource R003 kits 10 cajas acopio_1 centro", coord)

      {{:ok, all}, _} = run("list_resources", coord)
      assert length(all) == 3

      {{:ok, _}, out} = run("list_resources zona=centro", coord)
      assert out =~ "[R001]"
      assert out =~ "[R003]"
      refute out =~ "[R002]"

      {{:ok, _}, out} = run("list_resources tipo=agua ubicacion=acopio_2", coord)
      assert out =~ "[R002]"
      refute out =~ "[R001]"
    end

    test "resource_availability agrupa por tipo y zona", %{coord: coord} do
      {{:ok, _}, _} = run("register_resource R001 agua 50 litros acopio_1 centro", coord)
      {{:ok, _}, _} = run("register_resource R002 agua 30 litros acopio_2 norte", coord)

      {{:ok, _}, out} = run("resource_availability tipo=agua", coord)
      assert out =~ "agua: 80 litros"

      {{:ok, _}, out} = run("resource_availability zona=norte", coord)
      assert out =~ "agua: 30 litros"
      refute out =~ "80"
    end

    test "transfer_resource conserva la zona o usa la indicada", %{coord: coord} do
      {{:ok, _}, _} = run("register_resource R001 agua 50 litros acopio_1 centro", coord)

      {{:ok, %{to: to}}, out} = run("transfer_resource R001 acopio_1 albergue_1 15", coord)
      assert to.quantity == 15
      assert to.zone == "centro"
      assert out =~ "zona: centro"

      {{:ok, %{to: to}}, _} = run("transfer_resource R001 acopio_1 albergue_2 5 norte", coord)
      assert to.zone == "norte"
    end

    test "transfer_resource informa errores sin modificar el inventario", %{coord: coord} do
      {{:ok, _}, _} = run("register_resource R001 agua 50 litros acopio_1 centro", coord)

      assert {{:error, :ubicacion_destino_igual_al_origen}, _} =
               run("transfer_resource R001 acopio_1 acopio_1 5", coord)

      assert {{:error, :zona_no_encontrada}, _} =
               run("transfer_resource R001 acopio_1 albergue_1 5 nada", coord)

      assert {{:error, :cantidad_invalida}, _} =
               run("transfer_resource R001 acopio_1 albergue_1 xx", coord)

      {{:ok, [%{quantity: 50}]}, _} = run("list_resources", coord)
    end

    test "resource_history muestra el kardex de movimientos del recurso", %{coord: coord} do
      {{:ok, _}, _} = run("register_resource R001 agua 50 litros acopio_1 centro", coord)
      {{:ok, _}, _} = run("add_stock R001 20", coord)

      {{:ok, history}, out} = run("resource_history R001", coord)
      assert length(history) == 2
      assert out =~ "entrada: 20 litros"
      assert out =~ "registro_inicial: 50 litros"
    end
  end

  describe "usuarios, sesiones, necesidades, familiares, mascotas y albergues vía CLI" do
    test "register_user, user_activity y disconnect limpian la sesión activa", %{coord: coord} do
      assert {{:ok, u}, out} =
               run(~s(register_user pedro 9999 "Pedro Gómez" voluntario norte), coord)

      assert u.full_name == "Pedro Gómez"
      assert out =~ "Pedro Gómez"

      assert {{:ok, log}, out} = run("user_activity coord", coord)
      assert length(log) >= 1
      assert out =~ "Actividad de coord"

      before_count = EmergencySystem.Servers.SessionSupervisor.active_sessions_count()
      assert {{:ok, _}, _} = run("disconnect", coord)
      after_count = EmergencySystem.Servers.SessionSupervisor.active_sessions_count()
      assert after_count == before_count - 1
    end

    test "necesidades: next_need, update_need_status y asociación de entidad", %{coord: coord} do
      {{:ok, _}, _} = run(~s(register_zone centro "Zona Centro" critico), coord)
      {{:ok, n1}, _} = run(~s(register_need agua 20 media centro "Agua sector 1" A01), coord)
      {{:ok, n2}, _} = run(~s(register_need rescate 5 critica centro "Derrumbe puente"), coord)

      assert n1.entity_ref == "A01"

      assert {{:ok, best}, out} = run("next_need", coord)
      assert best.id == n2.id
      assert out =~ "PRIORIDAD MÁXIMA"

      assert {{:ok, updated}, _} = run("update_need_status #{n2.id} en_atencion", coord)
      assert updated.status == :en_atencion
    end

    test "personas, mensajes familiares y mark_message_delivered enlazan reportes a la zona", %{
      coord: coord,
      ciud: ciud
    } do
      {{:ok, _}, _} = run(~s(register_zone centro "Zona Centro" critico), coord)
      assert {{:ok, p}, _} = run(~s(report_person 1094 "Andrés Pérez" 29 centro localizada), ciud)
      assert p.age == 29

      assert {{:ok, msg}, _} =
               run(~s(send_family_message 1094 "Te esperamos en el albergue"), ciud)

      assert msg.status == :pendiente

      assert {{:ok, delivered}, out} = run("mark_message_delivered #{msg.id}", coord)
      assert delivered.status == :entregado
      assert out =~ "entregado"

      assert {:ok, {:ok, _}} = {:ok, EmergencySystem.Servers.ZoneManager.get_zone("centro")}
    end

    test "mascotas: report_pet con rasgos, list_pets, match_pets y confirm_match", %{
      coord: coord,
      ciud: ciud
    } do
      {{:ok, lost}, _} =
        run(~s(report_pet lost perro "Luna" "collar rojo" negra mediana norte 300111), ciud)

      {{:ok, found}, _} =
        run(~s(report_pet found perro desconocido "collar rojo" negra mediana norte 310222), coord)

      assert {{:ok, [m]}, _} = run("match_pets", coord)
      assert m.lost_id == lost.id
      assert m.found_id == found.id

      # Al encontrar coincidencia pasan a estado :posible_coincidencia
      assert {{:ok, candidates}, _} = run("list_pets estado=posible_coincidencia", coord)
      assert length(candidates) == 2

      assert {{:ok, %{lost: r_lost, found: r_found}}, _} =
               run("confirm_match #{lost.id} #{found.id}", coord)

      assert r_lost.status == :resuelta
      assert r_found.status == :resuelta
    end

    test "albergues: asociación de recursos, necesidades y ranking top_shelters", %{coord: coord} do
      {{:ok, _}, _} = run(~s(register_shelter A01 "Albergue Norte" norte 10), coord)
      {{:ok, _}, _} = run(~s(register_shelter A02 "Albergue Sur" sur 10), coord)
      {{:ok, _}, _} = run("register_entry A02 DOC1", coord)
      {{:ok, _}, _} = run("register_entry A02 DOC2", coord)
      {{:ok, _}, _} = run("register_entry A01 DOC3", coord)

      assert {{:ok, _}, _} = run("link_shelter_resource A01 R001", coord)
      assert {{:ok, _}, _} = run("link_shelter_need A01 N001", coord)

      assert {{:ok, info}, out} = run("check_shelter A01", coord)
      assert info.resources == ["R001"]
      assert info.needs == ["N001"]
      assert out =~ "Recursos: 1"
      assert out =~ "Necesidades: 1"

      assert {{:ok, [first, second]}, out} = run("top_shelters", coord)
      assert first.code == "A02"
      assert second.code == "A01"
      assert out =~ "20.0%"
    end

    test "broadcast_alert difunde alertas a las sesiones activas", %{coord: coord} do
      assert {{:ok, count}, out} = run(~s(broadcast_alert "Alerta de réplica"), coord)
      assert count >= 1
      assert out =~ "Alerta difundida"
    end
  end

  test "rechaza comandos desconocidos o con argumentos incorrectos", %{coord: coord} do
    assert {{:error, :comando_invalido}, _} = run("comando_inexistente", coord)
    assert {{:error, :comando_invalido}, _} = run("add_stock R001", coord)
    assert {{:error, :comando_invalido}, _} = run("zone_status", coord)
  end
end
