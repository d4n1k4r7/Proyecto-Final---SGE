defmodule EmergencySystem do
  @moduledoc """
  API principal del Sistema Distribuido de Coordinación y Gestión de Emergencias.
  """

  alias EmergencySystem.CLI.Dispatcher

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

  @doc "Inicia la consola interactiva de comandos."
  def start_cli, do: Dispatcher.start_interactive()

  @doc "Ejecuta un comando en formato texto."
  def cmd(command_str, user \\ nil), do: Dispatcher.execute_command(command_str, user)

  @doc "Obtiene el estado global consolidado del sistema."
  def global_summary do
    %{
      total_users: length(UserRegistry.list_users()),
      active_sessions: SessionSupervisor.active_sessions_count(),
      zones_count: length(ZoneManager.list_zones()),
      resources: ResourceManager.list_resources(),
      pending_needs: NeedManager.pending_needs(),
      people: FamilyRegistry.list_people(),
      shelters: ShelterManager.top_occupied_shelters(),
      pet_matches: PetMatcher.find_matches()
    }
  end

  @doc "Limpia todos los servidores y archivos de persistencia (útil para tests y demos)."
  def reset_all do
    UserRegistry.reset_state()
    ZoneManager.reset_state()
    ResourceManager.reset_state()
    NeedManager.reset_state()
    FamilyRegistry.reset_state()
    PetMatcher.reset_state()
    ShelterManager.reset_state()
    SessionSupervisor.reset_sessions()
    :ok
  end

  @doc """
  Ejecuta automáticamente el Flujo de Ejemplo oficial de la sección 1.4.10 del enunciado,
  demostrando múltiples roles y resolución de condiciones de carrera.
  """
  def run_demo_scenario do
    IO.puts("\n>>> INICIANDO SIMULACIÓN DEL FLUJO DE EJEMPLO (SECCIÓN 1.4.10) <<<\n")
    reset_all()

    # 1. Laura se conecta como coordinadora de la zona centro
    {_, laura} = Dispatcher.execute_command("connect laura 1234 coordinador centro", nil)
    Dispatcher.execute_command("register_zone centro \"Zona Centro\" critico", laura)
    Dispatcher.execute_command("register_zone zona_norte \"Zona Norte\" alto", laura)

    # 2. Registra una necesidad crítica de 30 litros de agua y otra de 25 litros
    Dispatcher.execute_command(
      "register_need agua 30 critica centro \"Punto de atención sector 3\"",
      laura
    )

    Dispatcher.execute_command(
      "register_need agua 25 alta centro \"Comedor comunitario sector 1\"",
      laura
    )

    # 3. El centro de acopio registra 50 litros disponibles
    Dispatcher.execute_command("register_resource R001 agua 50 litros centro_acopio_1", laura)

    # 4. CONFLICTO CONCURRENTE: Dos procesos intentan tomar 30L y 25L simultáneamente (Total 55L > 50L)
    IO.puts(
      "\n[CONCURRENCIA] Lanzando 2 procesos simultáneos pidiendo 30L (N001) y 25L (N002) sobre 50L disponibles..."
    )

    task1 = Task.async(fn -> NeedManager.assign_resource("N001", "agua", 30) end)
    task2 = Task.async(fn -> NeedManager.assign_resource("N002", "agua", 25) end)

    res1 = Task.await(task1)
    res2 = Task.await(task2)

    IO.puts("  -> Resultado Proceso 1 (N001 - 30L): #{inspect(res1)}")
    IO.puts("  -> Resultado Proceso 2 (N002 - 25L): #{inspect(res2)}\n")

    # 5. Registro de Albergue Norte, ciudadano reporta a Andrés y se registra su ingreso
    Dispatcher.execute_command("register_shelter A01 \"Albergue Norte\" zona_norte 150", laura)
    {_, ciudadano} = Dispatcher.execute_command("connect carlos 1111 ciudadano zona_norte", nil)

    Dispatcher.execute_command(
      "report_person 1094001 \"Andrés Pérez\" zona_norte localizada",
      ciudadano
    )

    Dispatcher.execute_command("register_entry A01 1094001", laura)

    # 6. Un familiar deja un mensaje para Andrés
    Dispatcher.execute_command(
      "send_family_message 1094001 \"Estoy bien, vamos camino al Albergue Norte\"",
      ciudadano
    )

    Dispatcher.execute_command("list_family_messages 1094001", ciudadano)

    # 7. Ciudadano reporta mascota perdida y voluntario reporta mascota encontrada en la misma zona
    Dispatcher.execute_command(
      "report_pet lost perro \"Luna\" negra mediana zona_norte 3001112233",
      ciudadano
    )

    {_, voluntario} =
      Dispatcher.execute_command("connect mateo 2222 voluntario zona_norte", nil)

    Dispatcher.execute_command(
      "report_pet found perro desconocido negra mediana zona_norte 3109998877",
      voluntario
    )

    Dispatcher.execute_command("match_pets", voluntario)

    # 8. Coordinadora consulta el resumen global
    Dispatcher.execute_command("summary", laura)
  end
end
