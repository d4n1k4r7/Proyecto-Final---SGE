defmodule EmergencySystem.Servers.ShelterConcurrencyTest do
  use ExUnit.Case, async: false

  alias EmergencySystem.Servers.ShelterManager

  setup do
    EmergencySystem.reset_all()
    :ok
  end

  test "10 procesos concurrentes sobre un albergue de cupo 5 solo admiten 5" do
    {:ok, _} = ShelterManager.register_shelter("A01", "Albergue Municipal", "centro", 5)

    results =
      1..10
      |> Enum.map(fn i ->
        Task.async(fn -> {"DOC#{i}", ShelterManager.register_entry("A01", "DOC#{i}")} end)
      end)
      |> Task.await_many()

    admitted = for {doc, {:ok, _}} <- results, do: doc
    rejected = for {_doc, {:error, :capacidad_maxima_alcanzada}} <- results, do: :rechazado

    assert length(admitted) == 5
    assert length(rejected) == 5
  end

  test "al registrar una salida se libera un cupo" do
    {:ok, _} = ShelterManager.register_shelter("A01", "Albergue Municipal", "centro", 2)
    {:ok, _} = ShelterManager.register_entry("A01", "D1")
    {:ok, _} = ShelterManager.register_entry("A01", "D2")
    assert {:error, :capacidad_maxima_alcanzada} = ShelterManager.register_entry("A01", "D3")

    assert {:ok, _} = ShelterManager.register_exit("A01", "D1")
    assert {:ok, _} = ShelterManager.register_entry("A01", "D3")
  end

  test "un albergue inexistente devuelve error" do
    assert {:error, :albergue_no_encontrado} = ShelterManager.register_entry("A99", "D1")
    assert {:error, :albergue_no_encontrado} = ShelterManager.register_exit("A99", "D1")
  end
end
