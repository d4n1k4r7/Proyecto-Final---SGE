defmodule EmergencySystem.CLI.Dispatcher do
  @moduledoc """
  Intérprete de comandos de texto y consola interactiva para operar el sistema
  según la especificación 1.4.10 del enunciado.
  """

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

  @doc """
  Inicia una consola interactiva (REPL) en la terminal para demostración en vivo.
  """
  def start_interactive do
    IO.puts("""
    ====================================================================
      SISTEMA DISTRIBUIDO DE COORDINACIÓN Y GESTIÓN DE EMERGENCIAS
      Universidad del Quindío - Programación III
      Escribe 'help' para ver comandos, 'demo' para el flujo 1.4.10 o 'exit'
    ====================================================================
    """)

    loop(nil)
  end

  defp loop(current_user) do
    prompt = if current_user, do: "[#{current_user}]> ", else: "[sin_sesion]> "

    case IO.gets(prompt) do
      :eof ->
        IO.puts("\nSaliendo del sistema...")

      {:error, _} ->
        IO.puts("\nError de lectura. Saliendo...")

      line ->
        cmd = String.trim(line)

        case cmd do
          "" ->
            loop(current_user)

          "exit" ->
            IO.puts("Cerrando consola de emergencias.")

          "help" ->
            print_help()
            loop(current_user)

          "demo" ->
            EmergencySystem.run_demo_scenario()
            loop(current_user)

          _ ->
            {_reply, next_user} = execute_command(cmd, current_user)
            loop(next_user)
        end
    end
  end

  @doc """
  Parsea y ejecuta una línea de comando como string, retornando `{resultado, usuario_actual}`.
  Respeta texto entre comillas dobles (ej. "Albergue Norte").
  """
  def execute_command(command_line, current_user \\ nil) when is_binary(command_line) do
    tokens = tokenize(command_line)
    dispatch(tokens, current_user)
  end

  # Tokenizador que respeta comillas dobles
  defp tokenize(str) do
    ~r/"([^"]*)"|(\S+)/
    |> Regex.scan(str)
    |> Enum.map(fn
      [_, quoted] when quoted != "" -> quoted
      [_, "", word] -> word
      [full | _] -> String.trim(full, "\"")
    end)
  end

  # --- Comandos de Conexión y Sesión (1.4.1 / 1.4.2) ---

  defp dispatch(["register_user", username, password, full_name, role_str, zone], current_user) do
    with :ok <- check_auth(current_user, :register_user),
         {:ok, user} <-
           UserRegistry.register_user(
             username,
             password,
             full_name,
             safe_to_atom(role_str),
             zone
           ) do
      audit(current_user, "register_user #{user.username}")
      IO.puts("[OK] Usuario registrado: #{user.username} (#{user.full_name}) - Rol: #{user.role} en #{user.zone}")
      {{:ok, user}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["connect", username, password], _current_user) do
    dispatch(["connect", username, password, "ciudadano", "centro"], nil)
  end

  defp dispatch(["connect", username, password, role_str, zone], _current_user) do
    role = safe_to_atom(role_str)

    case UserRegistry.connect(username, password, role, zone) do
      {:ok, status, user} ->
        {:ok, _pid} = SessionSupervisor.start_user_session(user.username)
        msg = "Usuario '#{user.username}' (#{user.role}) #{status} en zona #{user.zone}."
        IO.puts("[OK] #{msg}")
        {{:ok, user}, user.username}

      {:error, reason} = err ->
        IO.puts("[ERROR] No se pudo conectar: #{inspect(reason)}")
        {err, nil}
    end
  end

  defp dispatch(["disconnect"], nil) do
    IO.puts("[ERROR] No hay ningún usuario conectado actualmente.")
    {{:error, :no_conectado}, nil}
  end

  defp dispatch(["disconnect"], current_user) do
    res = UserRegistry.disconnect(current_user)
    _ = SessionSupervisor.stop_user_session(current_user)
    IO.puts("[OK] Usuario '#{current_user}' desconectado.")
    {res, nil}
  end

  defp dispatch(["user_activity"], current_user) when is_binary(current_user) do
    dispatch(["user_activity", current_user], current_user)
  end

  defp dispatch(["user_activity", username], current_user) do
    case UserRegistry.get_user(username) do
      {:ok, user} ->
        IO.puts("--- Actividad de #{user.username} (#{user.role}) ---")

        Enum.each(user.activity_log, fn {dt, action} ->
          IO.puts("  [#{DateTime.to_iso8601(dt)}] #{action}")
        end)

        {{:ok, user.activity_log}, current_user}

      err ->
        report_error(err, current_user)
    end
  end

  # --- Gestión de Zonas (1.4.3) ---

  defp dispatch(["register_zone", code, name, level_str], current_user) do
    dispatch(["register_zone", code, name, level_str, "0"], current_user)
  end

  defp dispatch(["register_zone", code, name, level_str, affected_str], current_user) do
    with :ok <- check_auth(current_user, :register_zone),
         {affected, ""} <- Integer.parse(affected_str),
         {:ok, zone} <- ZoneManager.register_zone(code, name, safe_to_atom(level_str), affected) do
      audit(current_user, "register_zone #{code}")
      IO.puts("[OK] Zona registrada: #{zone.code} (#{zone.name}) - Nivel: #{zone.impact_level} | Afectados base: #{zone.estimated_affected}")
      {{:ok, zone}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["add_sector", zone_code, sector_code, name, level_str], current_user) do
    dispatch(["add_sector", zone_code, sector_code, name, level_str, "0"], current_user)
  end

  defp dispatch(
         ["add_sector", zone_code, sector_code, name, level_str, affected_str],
         current_user
       ) do
    with :ok <- check_auth(current_user, :add_sector),
         {affected, ""} <- Integer.parse(affected_str),
         {:ok, zone} <-
           ZoneManager.add_sector(zone_code, sector_code, name, safe_to_atom(level_str), affected) do
      audit(current_user, "add_sector #{zone_code}/#{sector_code}")
      IO.puts("[OK] Sector #{sector_code} (#{name}) agregado a la zona #{zone_code}.")
      {{:ok, zone}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(
         ["add_attention_point", zone_code, sector_code, point_id, name, people_str],
         current_user
       ) do
    with :ok <- check_auth(current_user, :add_attention_point),
         {people, ""} <- Integer.parse(people_str),
         {:ok, zone} <- ZoneManager.add_attention_point(zone_code, sector_code, point_id, name, people) do
      audit(current_user, "add_attention_point #{zone_code}/#{sector_code}/#{point_id}")
      IO.puts("[OK] Punto de atención #{point_id} (#{name}) agregado al sector #{sector_code}.")
      {{:ok, zone}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["zone_status", zone_code], current_user) do
    with :ok <- check_auth(current_user, :view_summary),
         {:ok, %{zone: zone, accumulated_stats: stats, links: links}} <-
           ZoneManager.get_zone_status(zone_code) do
      audit(current_user, "zone_status #{zone_code}")

      IO.puts("""
      Zona #{zone.code} (#{zone.name}) - Nivel: #{zone.impact_level}
        Sectores: #{stats.sectors_count} | Puntos de atención: #{stats.total_attention_points}
        Afectados acumulados: #{stats.total_accumulated_affected}
        Asociados -> albergues: #{links.shelters}, necesidades: #{links.needs}, recursos: #{links.resources}, reportes: #{links.reports}
      """)

      {{:ok, zone}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  # --- Gestión de Necesidades (1.4.4) ---

  defp dispatch(["register_need", type_str, qty_str, prio_str, zone, description | entity_opt], current_user)
       when length(entity_opt) <= 1 do
    entity_ref = List.first(entity_opt)

    with :ok <- check_auth(current_user, :register_need),
         {qty, ""} <- Integer.parse(qty_str),
         {:ok, need} <-
           NeedManager.register_need(
             nil,
             safe_to_atom(type_str),
             description,
             qty,
             zone,
             safe_to_atom(prio_str),
             current_user || "sistema",
             entity_ref
           ) do
      audit(current_user, "register_need #{need.id}")

      IO.puts(
        "[OK] Necesidad #{need.id} registrada: #{need.type} (#{need.quantity_required}) Prioridad: #{need.priority}"
      )

      {{:ok, need}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["update_need_status", need_id, new_status_str], current_user) do
    with :ok <- check_auth(current_user, :update_need_status),
         {:ok, updated} <-
           NeedManager.update_status(String.upcase(need_id), safe_to_atom(new_status_str)) do
      audit(current_user, "update_need_status #{need_id} #{new_status_str}")
      IO.puts("[OK] Necesidad #{updated.id} actualizada a estado: #{updated.status}")
      {{:ok, updated}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["list_needs" | filter_tokens], current_user) do
    criteria = parse_kv_filters(filter_tokens)
    needs = NeedManager.list_needs(criteria)

    IO.puts("--- Listado de Necesidades (Ordenadas por Prioridad) ---")

    Enum.each(needs, fn n ->
      IO.puts(
        "  [#{n.id}] Prioridad: #{n.priority} | Tipo: #{n.type} | Req: #{n.quantity_required} (Asig: #{n.quantity_assigned}) | Zona: #{n.zone} | Estado: #{n.status} | Desc: #{n.description}"
      )
    end)

    {{:ok, needs}, current_user}
  end

  defp dispatch(["pending_needs"], current_user) do
    needs = NeedManager.pending_needs()
    IO.puts("--- Necesidades Pendientes (#{length(needs)}) ---")

    Enum.each(needs, fn n ->
      IO.puts("  [#{n.id}] #{n.priority} - #{n.type}: #{n.quantity_required} en #{n.zone} (#{n.status})")
    end)

    {{:ok, needs}, current_user}
  end

  defp dispatch(["next_need"], current_user) do
    case NeedManager.next_priority_need() do
      {:ok, n} ->
        IO.puts("[PRIORIDAD MÁXIMA] [#{n.id}] Prioridad: #{n.priority} | Tipo: #{n.type} (#{n.quantity_required}) en #{n.zone} - #{n.description}")
        {{:ok, n}, current_user}

      err ->
        report_error(err, current_user)
    end
  end

  defp dispatch(["assign_resource", need_id, res_identifier, qty_str], current_user) do
    with :ok <- check_auth(current_user, :assign_resource),
         {qty, ""} <- Integer.parse(qty_str),
         {:ok, %{need: need, resource: res}} <-
           NeedManager.assign_resource(String.upcase(need_id), res_identifier, qty) do
      audit(current_user, "assign_resource #{need_id} #{res_identifier} #{qty}")

      IO.puts(
        "[OK] Asignados #{qty} #{res.unit} de #{res.name} a necesidad #{need.id} (Estado: #{need.status}, Stock restante: #{res.quantity})"
      )

      {{:ok, %{need: need, resource: res}}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  # --- Gestión de Recursos y Centros de Apoyo (1.4.5) ---

  defp dispatch(
         ["register_resource", code, name, qty_str, unit, location | zone_opt],
         current_user
       )
       when length(zone_opt) <= 1 do
    zone = List.first(zone_opt)

    with :ok <- check_auth(current_user, :register_resource),
         {qty, ""} <- Integer.parse(qty_str),
         {:ok, res} <-
           ResourceManager.register_resource(
             code,
             name,
             safe_to_atom(name),
             qty,
             unit,
             location,
             zone
           ) do
      audit(current_user, "register_resource #{code}")

      IO.puts(
        "[OK] Recurso #{res.code} (#{res.name}) registrado: #{res.quantity} #{res.unit} en #{res.location} (Zona: #{res.zone || "sin zona"})"
      )

      {{:ok, res}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["add_stock", code, qty_str], current_user) do
    with :ok <- check_auth(current_user, :add_stock),
         {qty, ""} <- Integer.parse(qty_str),
         {:ok, res} <- ResourceManager.add_stock(code, qty) do
      audit(current_user, "add_stock #{code} #{qty}")
      IO.puts("[OK] Entrada de #{qty} #{res.unit} en #{res.code}. Stock actual: #{res.quantity}")
      {{:ok, res}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["list_resources" | filter_tokens], current_user) do
    filters =
      Enum.reduce(filter_tokens, [], fn token, acc ->
        case String.split(token, "=", parts: 2) do
          ["zona", val] -> [{:zone, val} | acc]
          ["tipo", val] -> [{:category, safe_to_atom(val)} | acc]
          ["ubicacion", val] -> [{:location, val} | acc]
          _ -> acc
        end
      end)

    resources = ResourceManager.list_resources(filters)
    IO.puts("--- Inventario de Recursos ---")

    Enum.each(resources, fn r ->
      IO.puts(
        "  [#{r.code}] #{r.name}: #{r.quantity} #{r.unit} | Ubicación: #{r.location} | Zona: #{r.zone || "-"}"
      )
    end)

    {{:ok, resources}, current_user}
  end

  defp dispatch(["resource_availability" | filter_tokens], current_user) do
    filters =
      Enum.reduce(filter_tokens, [], fn token, acc ->
        case String.split(token, "=", parts: 2) do
          ["zona", val] -> [{:zone, val} | acc]
          ["tipo", val] -> [{:category, safe_to_atom(val)} | acc]
          _ -> acc
        end
      end)

    summary = ResourceManager.availability(filters)
    IO.puts("--- Disponibilidad de Recursos ---")

    Enum.each(summary, fn g ->
      IO.puts("  #{g.category}: #{g.total} #{g.unit} (#{Enum.join(g.resources, ", ")})")
    end)

    {{:ok, summary}, current_user}
  end

  defp dispatch(["resource_history", code], current_user) do
    case ResourceManager.get_resource(code) do
      {:ok, res} ->
        IO.puts("--- Historial de Movimientos de #{res.code} (#{res.name}) ---")

        Enum.each(res.history, fn {dt, type, amount, reason} ->
          IO.puts("  [#{DateTime.to_iso8601(dt)}] #{type}: #{amount} #{res.unit} (#{reason})")
        end)

        {{:ok, res.history}, current_user}

      err ->
        report_error(err, current_user)
    end
  end

  defp dispatch(["critical_resources"], current_user) do
    critical = ResourceManager.critical_resources()
    IO.puts("--- Recursos en Nivel Crítico (<= 20 unidades) ---")

    Enum.each(critical, fn r ->
      IO.puts("  [#{r.code}] #{r.name}: #{r.quantity} #{r.unit} en #{r.location}")
    end)

    {{:ok, critical}, current_user}
  end

  defp dispatch(
         ["transfer_resource", code, from_loc, to_loc, qty_str | zone_opt],
         current_user
       )
       when length(zone_opt) <= 1 do
    to_zone = List.first(zone_opt)

    with :ok <- check_auth(current_user, :transfer_resource),
         {qty, ""} <- Integer.parse(qty_str),
         {:ok, result} <- ResourceManager.transfer_resource(code, from_loc, to_loc, qty, to_zone) do
      audit(current_user, "transfer_resource #{code} #{from_loc}->#{to_loc} (#{qty})")

      IO.puts(
        "[OK] Transferidos #{qty} de #{code} desde #{from_loc} (restante: #{result.from.quantity}) hacia #{to_loc} (total: #{result.to.quantity}, zona: #{result.to.zone || "sin zona"})"
      )

      {{:ok, result}, current_user}
    else
      :error -> report_error({:error, :cantidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :cantidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  # --- Comunicación entre Familiares (1.4.6) ---

  defp dispatch(["report_person", document, name, zone, status_str], current_user) do
    dispatch(["report_person", document, name, "30", zone, status_str], current_user)
  end

  defp dispatch(["report_person", document, name, age_str, zone, status_str], current_user) do
    with :ok <- check_auth(current_user, :report_person),
         {age, ""} <- Integer.parse(age_str),
         {:ok, person} <-
           FamilyRegistry.report_person(document, name, age, zone, safe_to_atom(status_str)) do
      audit(current_user, "report_person #{document}")

      IO.puts(
        "[OK] Persona registrada/actualizada: #{person.name} (Doc: #{person.document}, Edad: #{person.age}) - Estado: #{person.status} en #{person.zone}"
      )

      {{:ok, person}, current_user}
    else
      :error -> report_error({:error, :edad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :edad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["find_person", query], current_user) do
    {:ok, result} = FamilyRegistry.find_person(query)
    IO.puts("--- Resultado de Búsqueda de Persona: #{inspect(result)} ---")
    {{:ok, result}, current_user}
  end

  defp dispatch(["send_family_message", doc, content], current_user) do
    sender = current_user || "familiar_anonimo"

    with :ok <- check_auth(current_user, :send_family_message),
         {:ok, msg} <- FamilyRegistry.send_family_message(sender, doc, content) do
      audit(current_user, "send_family_message #{doc}")
      IO.puts("[OK] Mensaje #{msg.id} enviado a documento #{doc}: \"#{msg.content}\"")
      {{:ok, msg}, current_user}
    else
      err ->
        report_error(err, current_user)
    end
  end

  defp dispatch(["list_family_messages", doc], current_user) do
    msgs = FamilyRegistry.list_family_messages(doc)
    IO.puts("--- Mensajes Familiares para #{doc} (#{length(msgs)}) ---")

    Enum.each(msgs, fn m ->
      IO.puts("  [#{m.id}] De #{m.sender}: \"#{m.content}\" (#{m.status})")
    end)

    {{:ok, msgs}, current_user}
  end

  defp dispatch(["mark_message_delivered", msg_id], current_user) do
    with :ok <- check_auth(current_user, :mark_message_delivered),
         {:ok, msg} <- FamilyRegistry.mark_message_delivered(String.upcase(msg_id)) do
      audit(current_user, "mark_message_delivered #{msg.id}")
      IO.puts("[OK] Mensaje #{msg.id} para #{msg.recipient_doc} marcado como #{msg.status}.")
      {{:ok, msg}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  # --- Gestión de Mascotas (1.4.7) ---

  defp dispatch(["report_pet", type_str, species, name, color, size_str, zone, contact], current_user) do
    dispatch(
      ["report_pet", type_str, species, name, color, color, size_str, zone, contact],
      current_user
    )
  end

  defp dispatch(
         ["report_pet", type_str, species, name, traits, color, size_str, zone, contact],
         current_user
       ) do
    type =
      case String.downcase(type_str) do
        "lost" -> :perdida
        "perdida" -> :perdida
        "found" -> :encontrada
        "encontrada" -> :encontrada
        other -> safe_to_atom(other)
      end

    with :ok <- check_auth(current_user, :report_pet),
         {:ok, pet} <-
           PetMatcher.report_pet(
             type,
             species,
             name,
             traits,
             color,
             safe_to_atom(size_str),
             zone,
             contact
           ) do
      audit(current_user, "report_pet #{pet.id}")

      IO.puts(
        "[OK] Mascota #{pet.id} (#{pet.type}): #{pet.species} '#{pet.name}', color #{pet.color}, tamaño #{pet.size} en #{pet.zone}"
      )

      {{:ok, pet}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["list_pets" | filter_tokens], current_user) do
    filters =
      Enum.reduce(filter_tokens, [], fn token, acc ->
        case String.split(token, "=", parts: 2) do
          ["especie", val] -> [{:species, val} | acc]
          ["zona", val] -> [{:zone, val} | acc]
          ["estado", val] -> [{:status, safe_to_atom(val)} | acc]
          _ -> acc
        end
      end)

    pets = PetMatcher.list_reports(filters)
    IO.puts("--- Reportes de Mascotas (#{length(pets)}) ---")

    Enum.each(pets, fn p ->
      IO.puts(
        "  [#{p.id}] #{p.type} | #{p.species} '#{p.name}' (#{p.color}, #{p.size}) en #{p.zone} | Estado: #{p.status}"
      )
    end)

    {{:ok, pets}, current_user}
  end

  defp dispatch(["match_pets"], current_user) do
    matches = PetMatcher.find_matches()
    IO.puts("--- Posibles Coincidencias de Mascotas (#{length(matches)}) ---")

    Enum.each(matches, fn m ->
      IO.puts(
        "  Perdida [#{m.lost_id}] <-> Encontrada [#{m.found_id}] | Especie: #{m.species} | Zona: #{m.zone} | Puntaje Similitud: #{m.score}/100"
      )
    end)

    {{:ok, matches}, current_user}
  end

  defp dispatch(["confirm_match", lost_id, found_id], current_user) do
    with :ok <- check_auth(current_user, :confirm_match),
         {:ok, res} <-
           PetMatcher.confirm_match(String.upcase(lost_id), String.upcase(found_id)) do
      audit(current_user, "confirm_match #{lost_id} #{found_id}")

      IO.puts(
        "[OK] Coincidencia confirmada y reportes cerrados: #{res.lost.id} <-> #{res.found.id} (Estado: #{res.lost.status})"
      )

      {{:ok, res}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  # --- Gestión de Albergues (1.4.8) ---

  defp dispatch(["register_shelter", code, name, zone, cap_str], current_user) do
    with :ok <- check_auth(current_user, :register_shelter),
         {cap, ""} <- Integer.parse(cap_str),
         {:ok, shelter} <- ShelterManager.register_shelter(code, name, zone, cap) do
      audit(current_user, "register_shelter #{code}")

      IO.puts(
        "[OK] Albergue #{shelter.code} (#{shelter.name}) registrado en #{shelter.zone} con capacidad #{shelter.max_capacity}"
      )

      {{:ok, shelter}, current_user}
    else
      :error -> report_error({:error, :capacidad_invalida}, current_user)
      {:error, _} = err -> report_error(err, current_user)
      {_number, _rest} -> report_error({:error, :capacidad_invalida}, current_user)
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["check_shelter", code], current_user) do
    case ShelterManager.check_shelter(code) do
      {:ok, info} ->
        s = info.shelter

        IO.puts(
          "[ALBERGUE #{s.code}] #{s.name} | Ocupación: #{s.current_occupancy}/#{s.max_capacity} (#{info.occupancy_percentage}%) | Cupos disponibles: #{info.available_spots} | Recursos: #{length(info.resources)} | Necesidades: #{length(info.needs)}"
        )

        {{:ok, info}, current_user}

      err ->
        report_error(err, current_user)
    end
  end

  defp dispatch(["register_entry", shelter_code, doc], current_user) do
    with :ok <- check_auth(current_user, :register_entry),
         {:ok, s} <- ShelterManager.register_entry(shelter_code, doc) do
      audit(current_user, "register_entry #{shelter_code} #{doc}")

      IO.puts(
        "[OK] Ingreso registrado para #{doc} en #{s.name} (Ocupación: #{s.current_occupancy}/#{s.max_capacity})"
      )

      {{:ok, s}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["register_exit", shelter_code, doc], current_user) do
    with :ok <- check_auth(current_user, :register_exit),
         {:ok, s} <- ShelterManager.register_exit(shelter_code, doc) do
      audit(current_user, "register_exit #{shelter_code} #{doc}")

      IO.puts(
        "[OK] Salida registrada para #{doc} en #{s.name} (Ocupación: #{s.current_occupancy}/#{s.max_capacity})"
      )

      {{:ok, s}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["link_shelter_resource", shelter_code, resource_code], current_user) do
    with :ok <- check_auth(current_user, :link_shelter),
         {:ok, s} <- ShelterManager.link_resource(shelter_code, resource_code) do
      audit(current_user, "link_shelter_resource #{shelter_code} #{resource_code}")
      IO.puts("[OK] Recurso #{resource_code} asociado al albergue #{s.code} (#{s.name}).")
      {{:ok, s}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["link_shelter_need", shelter_code, need_id], current_user) do
    with :ok <- check_auth(current_user, :link_shelter),
         {:ok, s} <- ShelterManager.link_need(shelter_code, need_id) do
      audit(current_user, "link_shelter_need #{shelter_code} #{need_id}")
      IO.puts("[OK] Necesidad #{need_id} asociada al albergue #{s.code} (#{s.name}).")
      {{:ok, s}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  defp dispatch(["top_shelters"], current_user) do
    shelters = ShelterManager.top_occupied_shelters()
    IO.puts("--- Albergues con Mayor Nivel de Ocupación (#{length(shelters)}) ---")

    Enum.each(shelters, fn s ->
      pct = EmergencySystem.Core.Shelter.occupancy_percentage(s)

      IO.puts(
        "  [#{s.code}] #{s.name} (Zona: #{s.zone}) -> #{s.current_occupancy}/#{s.max_capacity} (#{pct}%)"
      )
    end)

    {{:ok, shelters}, current_user}
  end

  defp dispatch(["broadcast_alert", message], current_user) do
    with :ok <- check_auth(current_user, :broadcast_alert),
         {:ok, count} <- SessionSupervisor.AlertBroadcaster.broadcast(message) do
      audit(current_user, "broadcast_alert")
      IO.puts("[OK] Alerta difundida a #{count} sesiones activas: \"#{message}\"")
      {{:ok, count}, current_user}
    else
      err -> report_error(err, current_user)
    end
  end

  # --- Resumen Global del Sistema ---

  defp dispatch(["summary"], current_user) do
    summary = EmergencySystem.global_summary()

    IO.puts("""
    ================ RESUMEN GLOBAL DE LA EMERGENCIA ================
    * Usuarios registrados     : #{summary.total_users} (Sesiones activas: #{summary.active_sessions})
    * Zonas registradas        : #{summary.zones_count}
    * Recursos en inventario   : #{length(summary.resources)} lotes
    * Necesidades pendientes   : #{length(summary.pending_needs)}
    * Personas registradas     : #{length(summary.people)}
    * Albergues activos        : #{length(summary.shelters)}
    * Coincidencias mascotas   : #{length(summary.pet_matches)}
    =================================================================
    """)

    {{:ok, summary}, current_user}
  end

  defp dispatch(unknown, current_user) do
    IO.puts("[ERROR] Comando no reconocido o argumentos inválidos: #{inspect(unknown)}")
    {{:error, :comando_invalido}, current_user}
  end

  # --- Utilidades Internas ---

  defp check_auth(nil, _op), do: :ok
  defp check_auth(username, op), do: UserRegistry.authorize(username, op)

  defp audit(nil, _action), do: :ok
  defp audit(username, action), do: UserRegistry.log_action(username, action)

  defp report_error(err, current_user) do
    IO.puts("[ERROR] #{inspect(err)}")
    {err, current_user}
  end

  defp parse_kv_filters(tokens) do
    Enum.reduce(tokens, [], fn token, acc ->
      case String.split(token, "=", parts: 2) do
        ["zona", val] -> [{:zone, val} | acc]
        ["prioridad", val] -> [{:priority, safe_to_atom(val)} | acc]
        ["estado", val] -> [{:status, safe_to_atom(val)} | acc]
        ["tipo", val] -> [{:type, safe_to_atom(val)} | acc]
        _ -> acc
      end
    end)
  end

  defp safe_to_atom(str) when is_binary(str) do
    str |> String.trim() |> String.downcase() |> String.to_atom()
  end

  defp print_help do
    IO.puts("""
    Comandos disponibles:
      connect <usuario> <password> [rol] [zona]
      disconnect
      register_user <usuario> <password> "<nombre_completo>" <rol> <zona>
      user_activity [usuario]
      register_zone <codigo> "<nombre>" <nivel> [afectados]
      add_sector <zona> <codigo_sector> "<nombre>" <nivel> [afectados]
      add_attention_point <zona> <sector> <id_punto> "<nombre>" <personas_afectadas>
      zone_status <zona>
      register_need <tipo> <cantidad> <prioridad> <zona> "<descripcion>" [entidad_asociada]
      update_need_status <id_necesidad> <nuevo_estado>
      list_needs [zona=X] [prioridad=Y] [estado=Z] [tipo=W]
      pending_needs
      next_need
      register_resource <codigo> <nombre> <cantidad> <unidad> <ubicacion> [zona]
      add_stock <codigo> <cantidad>
      list_resources [zona=X] [tipo=Y] [ubicacion=Z]
      resource_availability [zona=X] [tipo=Y]
      resource_history <codigo>
      critical_resources
      assign_resource <id_necesidad> <recurso> <cantidad>
      transfer_resource <codigo> <origen> <destino> <cantidad> [zona_destino]
      report_person <documento> "<nombre>" [edad] <zona> <estado>
      find_person <documento_o_nombre_o_zona_o_estado>
      send_family_message <documento> "<mensaje>"
      list_family_messages <documento>
      mark_message_delivered <id_mensaje>
      report_pet <lost|found> <especie> "<nombre>" ["<caracteristicas>"] <color> <pequena|mediana|grande> <zona> <contacto>
      list_pets [especie=X] [zona=Y] [estado=Z]
      match_pets
      confirm_match <id_perdida> <id_encontrada>
      register_shelter <codigo> "<nombre>" <zona> <capacidad>
      check_shelter <codigo>
      register_entry <codigo_albergue> <documento>
      register_exit <codigo_albergue> <documento>
      link_shelter_resource <codigo_albergue> <codigo_recurso>
      link_shelter_need <codigo_albergue> <id_necesidad>
      top_shelters
      broadcast_alert "<mensaje>"
      summary
      demo
      exit
    """)
  end
end
