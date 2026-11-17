defmodule EmergencySystem.Storage.TextStorageTest do
  # No async: cambia la configuración global :data_dir para no tocar data/.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias EmergencySystem.Core.{Resource, Zone}
  alias EmergencySystem.Storage.TextStorage

  setup do
    dir = Path.join(System.tmp_dir!(), "ers_storage_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:emergency_system, :data_dir)
    Application.put_env(:emergency_system, :data_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:emergency_system, :data_dir, previous),
        else: Application.delete_env(:emergency_system, :data_dir)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "guarda y carga structs con fechas y MapSet sin perder información" do
    {:ok, res} = Resource.new("R001", "agua", :agua, 50, "litros", "acopio_1", "Z1")
    {:ok, zone} = Zone.new("Z1", "Centro", :critico, 100)
    {:ok, zone} = Zone.link_entity(zone, :resources, "R001")

    assert {:ok, _path} = TextStorage.save_records("mezcla.txt", [res, zone])
    assert {:ok, [loaded_res, loaded_zone]} = TextStorage.load_records("mezcla.txt")
    assert loaded_res == res
    assert loaded_zone == zone
  end

  test "el archivo es texto legible con encabezado", %{dir: dir} do
    {:ok, res} = Resource.new("R001", "agua", :agua, 50, "litros", "acopio_1")
    {:ok, _} = TextStorage.save_records("legible.txt", [res])

    content = File.read!(Path.join(dir, "legible.txt"))
    assert content =~ "# EmergencySystem TextStorage v1"
    assert content =~ ~s(%EmergencySystem.Core.Resource{)
    assert content =~ ~s(name: "agua")
    refute File.exists?(Path.join(dir, "legible.txt.tmp"))
  end

  test "conserva cadenas con saltos de línea, comillas, barras verticales y tildes" do
    records = [%{texto: "línea 1\nlínea 2 | \"citado\" ñandú ✓", n: -5, f: 1.5, t: {1, :a, "x"}}]
    {:ok, _} = TextStorage.save_records("cadenas.txt", records)
    assert {:ok, ^records} = TextStorage.load_records("cadenas.txt")
  end

  test "mantiene el orden de los registros" do
    records = Enum.map(1..50, &%{id: &1})
    {:ok, _} = TextStorage.save_records("orden.txt", records)
    assert {:ok, ^records} = TextStorage.load_records("orden.txt")
  end

  test "rechaza registros no serializables sin tocar el archivo existente", %{dir: dir} do
    {:ok, _} = TextStorage.save_records("seguro.txt", [%{ok: 1}])

    assert {:error, {:registro_no_serializable, _}} =
             TextStorage.save_records("seguro.txt", [%{pid: self()}])

    assert {:ok, [%{ok: 1}]} = TextStorage.load_records("seguro.txt")
    refute File.exists?(Path.join(dir, "seguro.txt.tmp"))
  end

  test "no ejecuta código ni acepta structs ajenos al sistema", %{dir: dir} do
    File.write!(Path.join(dir, "manipulado.txt"), """
    # EmergencySystem TextStorage v1
    %{a: 1}
    System.cmd("echo", ["hola"])
    %URI{host: "x"}
    File.rm_rf!("/tmp/algo")
    :ok
    """)

    assert {:ok, [%{a: 1}, :ok]} = TextStorage.load_records("manipulado.txt")
  end

  test "omite líneas corruptas y sigue leyendo", %{dir: dir} do
    File.write!(Path.join(dir, "corrupto.txt"), """
    # EmergencySystem TextStorage v1
    %{a: 1}
    %{a: [1, 2
    %{a: 3}
    """)

    assert {:ok, [%{a: 1}, %{a: 3}]} = TextStorage.load_records("corrupto.txt")
  end

  test "completa campos nuevos de structs guardados con una versión anterior", %{dir: dir} do
    File.write!(Path.join(dir, "viejo.txt"), """
    # EmergencySystem TextStorage v1
    %EmergencySystem.Core.Resource{code: "R1", name: "agua", category: :agua, quantity: 5, unit: "l", location: "a", history: []}
    """)

    assert {:ok, [%Resource{code: "R1", zone: nil}]} = TextStorage.load_records("viejo.txt")
  end

  test "lee el formato anterior (Base64) y lo reescribe en el nuevo", %{dir: dir} do
    legacy = Base.encode64(:erlang.term_to_binary(%{id: 1, nombre: "Prueba"}))
    File.write!(Path.join(dir, "legacy.txt"), "#{legacy}|%{id: 1, nombre: \"Prueba\"}\n")

    assert {:ok, [%{id: 1, nombre: "Prueba"}] = records} = TextStorage.load_records("legacy.txt")
    {:ok, _} = TextStorage.save_records("legacy.txt", records)
    assert File.read!(Path.join(dir, "legacy.txt")) =~ "# EmergencySystem TextStorage v1"
    assert {:ok, ^records} = TextStorage.load_records("legacy.txt")
  end

  test "un archivo inexistente devuelve lista vacía" do
    assert {:ok, []} = TextStorage.load_records("no_existe.txt")
  end
end
