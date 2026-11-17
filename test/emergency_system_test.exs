defmodule EmergencySystemTest do
  use ExUnit.Case, async: false

  alias EmergencySystem.Algorithms.{ZoneTraversal, PriorityQueue, SimilarityEngine}
  alias EmergencySystem.Storage.TextStorage

  alias EmergencySystem.Servers.{
    UserRegistry,
    ZoneManager,
    ResourceManager,
    NeedManager,
    FamilyRegistry,
    PetMatcher,
    ShelterManager,
    SessionSupervisor
  }

  setup do
    EmergencySystem.reset_all()
    :ok
  end

  describe "1. Concurrencia y Condición de Carrera en Inventario (Requisito 1.4.5 y 1.4.10)" do
    test "impide sobreasignación cuando múltiples procesos compiten simultáneamente por las últimas unidades" do
      {:ok, _} = ResourceManager.register_resource("R001", "agua", :agua, 50, "litros", "acopio_1")

      {:ok, n1} = NeedManager.register_need("N001", :agua, "Sector 3", 30, "centro", :critica, "laura")
      {:ok, n2} = NeedManager.register_need("N002", :agua, "Sector 1", 25, "centro", :alta, "carlos")

      tasks = [
        Task.async(fn -> NeedManager.assign_resource(n1.id, "R001", 30) end),
        Task.async(fn -> NeedManager.assign_resource(n2.id, "R001", 25) end)
      ]

      results = Task.await_many(tasks)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &match?({:error, {:inventario_insuficiente, _}}, &1))

      assert length(successes) == 1
      assert length(failures) == 1

      [resource] = ResourceManager.list_resources()
      assert resource.quantity in [20, 25]
      assert resource.quantity >= 0
    end

    test "10 procesos concurrentes intentando reservar 10 unidades de un stock de 50 solo confirma 5" do
      {:ok, _} = ResourceManager.register_resource("R999", "kits", :medicamentos, 50, "cajas", "central")

      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            ResourceManager.allocate_resource("R999", 10, "Solicitud concurrente #{i}")
          end)
        end)
        |> Task.await_many()

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      err_count = Enum.count(results, &match?({:error, {:inventario_insuficiente, _}}, &1))

      assert ok_count == 5
      assert err_count == 5

      [res] = ResourceManager.list_resources()
      assert res.quantity == 0
    end
  end

  describe "2. Verificación de las 4 Funciones Recursivas Propias" do
    test "Recursión #1: recorrido jerárquico Zona -> Sectores -> Puntos de Atención en ZoneManager" do
      {:ok, _} = ZoneManager.register_zone("Z1", "Centro", :critico, 50)
      {:ok, _} = ZoneManager.add_sector("Z1", "S1", "Sector Norte", :critico, 100)
      {:ok, _} = ZoneManager.add_attention_point("Z1", "S1", "PA1", "Escuela", 40)
      {:ok, zone} = ZoneManager.add_attention_point("Z1", "S1", "PA2", "Coliseo", 60)

      stats = ZoneTraversal.calculate_zone_stats(zone)

      assert stats.sectors_count == 1
      assert stats.total_attention_points == 2
      assert stats.total_accumulated_affected == 50 + 100 + 40 + 60
    end

    test "Recursión #2: ordenamiento y filtrado recursivo de necesidades por peso de prioridad" do
      {:ok, _} = NeedManager.register_need("N1", :agua, "Agua", 10, "sur", :baja, "u1")
      {:ok, _} = NeedManager.register_need("N2", :rescate, "Rescate", 2, "centro", :critica, "u2")
      {:ok, _} = NeedManager.register_need("N3", :alimentos, "Comida", 50, "centro", :alta, "u3")

      ordered = NeedManager.list_needs()
      assert Enum.map(ordered, & &1.priority) == [:critica, :alta, :baja]

      filtered = PriorityQueue.filter_needs(ordered, zone: "centro")
      assert length(filtered) == 2
      assert hd(filtered).id == "N2"
    end

    test "Recursión #3: motor de similitud de mascotas perdidas y encontradas" do
      {:ok, lost} =
        PetMatcher.report_pet(:perdida, "perro", "Luna", "collar rojo", "negra", :mediana, "zona_norte", "300123")

      {:ok, found} =
        PetMatcher.report_pet(:encontrada, "perro", "desconocido", "collar rojo", "negra", :mediana, "zona_norte", "310999")

      assert SimilarityEngine.compute_similarity_score(lost, found) >= 95

      matches = PetMatcher.find_matches()
      assert length(matches) == 1
      [match] = matches

      assert {:ok, _} = PetMatcher.confirm_match(match.lost_id, match.found_id)
      assert {:error, :reporte_ya_resuelto} = PetMatcher.confirm_match(match.lost_id, match.found_id)
    end

    test "Recursión #4: persistencia y reconstrucción desde archivos de texto plano" do
      data = [%{id: 1, nombre: "Prueba 1"}, %{id: 2, nombre: "Prueba 2"}]
      assert {:ok, _path} = TextStorage.save_records("test_recursion.txt", data)
      assert {:ok, loaded} = TextStorage.load_records("test_recursion.txt")
      assert loaded == data

      # El archivo es texto plano legible (no binario codificado)
      content = File.read!(Path.join(TextStorage.data_dir(), "test_recursion.txt"))
      assert content =~ "Prueba 1"
      assert String.valid?(content)
    end
  end

  describe "3. Albergues, Personas, Usuarios y Paso de Mensajes Puro" do
    test "controla el cupo máximo de un albergue y actualiza el estado de la persona en FamilyRegistry" do
      {:ok, _} = FamilyRegistry.report_person("DOC1", "Andrés Pérez", 28, "centro", :localizada)
      {:ok, _} = ShelterManager.register_shelter("A01", "Albergue Municipal", "centro", 2)

      assert {:ok, _} = ShelterManager.register_entry("A01", "DOC1")
      {:ok, person} = FamilyRegistry.find_person("DOC1")
      assert person.status == :en_albergue

      assert {:ok, _} = ShelterManager.register_entry("A01", "DOC2")
      assert {:error, :capacidad_maxima_alcanzada} = ShelterManager.register_entry("A01", "DOC3")

      {:ok, msg} = FamilyRegistry.send_family_message("Familiar", "DOC1", "Estamos en camino")
      assert {:ok, delivered} = FamilyRegistry.mark_message_delivered(msg.id)
      assert delivered.status == :entregado
    end

    test "autenticación automática en connect y difusión de alertas por send/receive puro" do
      assert {:ok, :registrado_y_conectado, user} =
               UserRegistry.connect("laura", "1234", :coordinador, "centro")

      assert user.connected == true
      {:ok, session_pid} = SessionSupervisor.start_user_session("laura")

      assert {:ok, count} =
               SessionSupervisor.AlertBroadcaster.broadcast("Réplica sísmica detectada")

      assert count >= 1
      state = GenServer.call(session_pid, :get_info)
      assert length(state.notifications) == 1
    end
  end
end
