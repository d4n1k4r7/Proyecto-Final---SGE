defmodule EmergencySystem.Core.UserTest do
  # Pruebas puras: no usan GenServers ni escriben en data/.
  use ExUnit.Case, async: true

  alias EmergencySystem.Core.User

  test "la contraseña se guarda con hash y no en texto plano" do
    {:ok, user} = User.new("ana", "secreto", "Ana", :ciudadano, "centro")
    refute user.password == "secreto"
    assert String.starts_with?(user.password, "sha256$")
  end

  test "dos usuarios con la misma contraseña tienen hashes distintos (sal)" do
    {:ok, a} = User.new("a", "igual", "A", :ciudadano, "z")
    {:ok, b} = User.new("b", "igual", "B", :ciudadano, "z")
    refute a.password == b.password
  end

  test "autentica con la contraseña correcta y rechaza la incorrecta" do
    {:ok, user} = User.new("ana", "secreto", "Ana", :ciudadano, "centro")
    assert {:ok, %User{connected: true}} = User.authenticate(user, "secreto")
    assert {:error, :credenciales_invalidas} = User.authenticate(user, "otra")
  end

  test "migra contraseñas antiguas en texto plano al autenticar" do
    legacy = %User{
      username: "viejo",
      password: "1234",
      full_name: "Viejo",
      role: :ciudadano,
      zone: "z"
    }

    assert {:ok, migrated} = User.authenticate(legacy, "1234")
    assert String.starts_with?(migrated.password, "sha256$")
    assert {:error, :credenciales_invalidas} = User.authenticate(legacy, "mal")
  end

  test "rechaza rol inválido y credenciales vacías" do
    assert {:error, {:rol_invalido, :rey, _}} = User.new("x", "y", "X", :rey, "z")
    assert {:error, :credenciales_vacias} = User.new("  ", "y", "X", :ciudadano, "z")
  end

  test "permisos por rol" do
    {:ok, u} = User.new("c", "1", "C", :ciudadano, "z")
    {:ok, u} = User.authenticate(u, "1")
    assert :ok = User.authorized?(u, :register_need)
    assert {:error, {:no_autorizado, :ciudadano, :register_zone}} = User.authorized?(u, :register_zone)

    {:ok, admin} = User.new("a", "1", "A", :administrador, "z")
    {:ok, admin} = User.authenticate(admin, "1")
    assert :ok = User.authorized?(admin, :cualquier_cosa)
  end

  test "usuario desconectado no está autorizado" do
    {:ok, u} = User.new("c", "1", "C", :coordinador, "z")
    assert {:error, :usuario_no_conectado} = User.authorized?(u, :register_zone)
  end
end
