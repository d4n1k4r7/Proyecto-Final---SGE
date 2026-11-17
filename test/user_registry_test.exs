defmodule EmergencySystem.Servers.UserRegistryTest do
  use ExUnit.Case, async: false

  alias EmergencySystem.Core.User
  alias EmergencySystem.Servers.UserRegistry

  setup do
    EmergencySystem.reset_all()
    :ok
  end

  test "connect registra automáticamente y guarda la contraseña con hash" do
    assert {:ok, :registrado_y_conectado, %User{connected: true}} =
             UserRegistry.connect("ana", "clave", :ciudadano, "centro")

    {:ok, stored} = UserRegistry.get_user("ana")
    refute stored.password == "clave"
    assert String.starts_with?(stored.password, "sha256$")
  end

  test "reconectar exige la contraseña correcta" do
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("ana", "clave")
    {:ok, _} = UserRegistry.disconnect("ana")

    assert {:error, :credenciales_invalidas} = UserRegistry.connect("ana", "mala")
    assert {:ok, :conectado, %User{connected: true}} = UserRegistry.connect("ana", "clave")
  end

  test "register_user rechaza duplicados y normaliza espacios en el nombre" do
    assert {:ok, %User{username: "bob"}} =
             UserRegistry.register_user(" bob ", "1234", "Bob", :voluntario, "norte")

    assert {:error, :usuario_ya_existe} =
             UserRegistry.register_user("bob", "1234", "Bob", :voluntario, "norte")

    assert {:ok, %User{username: "bob"}} = UserRegistry.get_user("bob")
  end

  test "register_user rechaza roles inválidos" do
    assert {:error, {:rol_invalido, :rey, _}} =
             UserRegistry.register_user("x", "1", "X", :rey, "z")
  end

  test "autorización por rol y por estado de conexión" do
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("cita", "1", :ciudadano, "centro")
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("coor", "1", :coordinador, "centro")
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("adm", "1", :administrador, "centro")

    assert :ok = UserRegistry.authorize("cita", :register_need)
    assert {:error, {:no_autorizado, :ciudadano, :register_zone}} =
             UserRegistry.authorize("cita", :register_zone)

    assert :ok = UserRegistry.authorize("coor", :register_zone)
    assert :ok = UserRegistry.authorize("coor", :add_stock)
    assert :ok = UserRegistry.authorize("adm", :cualquier_operacion)

    {:ok, _} = UserRegistry.disconnect("coor")
    assert {:error, :usuario_no_conectado} = UserRegistry.authorize("coor", :register_zone)
    assert {:error, :usuario_no_encontrado} = UserRegistry.authorize("fantasma", :register_need)
  end

  test "connected_users solo devuelve usuarios con sesión activa" do
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("a", "1")
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("b", "1")
    {:ok, _} = UserRegistry.disconnect("a")

    assert [%User{username: "b"}] = UserRegistry.connected_users()
  end

  test "log_action agrega la acción al historial del usuario" do
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("ana", "1")
    UserRegistry.log_action("ana", "Consulta de resumen")

    {:ok, user} = UserRegistry.get_user("ana")
    assert Enum.any?(user.activity_log, fn {_, action} -> action == "Consulta de resumen" end)
  end

  test "los usuarios sobreviven al reinicio del servidor y quedan desconectados" do
    {:ok, :registrado_y_conectado, _} = UserRegistry.connect("ana", "clave", :voluntario, "centro")

    restart(UserRegistry)

    assert {:ok, user} = UserRegistry.get_user("ana")
    refute user.connected
    assert user.role == :voluntario
    assert String.starts_with?(user.password, "sha256$")
    assert {:ok, :conectado, _} = UserRegistry.connect("ana", "clave")
  end

  # Mata el proceso y espera a que el supervisor lo reinicie (una sola vez por prueba
  # para no superar el máximo de reinicios del supervisor).
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
