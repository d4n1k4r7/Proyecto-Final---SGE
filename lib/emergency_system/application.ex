defmodule EmergencySystem.Application do
  @moduledoc """
  Árbol de Supervisión OTP principal del Sistema Distribuido de Coordinación y
  Gestión de Emergencias.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EmergencySystem.Servers.UserRegistry,
      EmergencySystem.Servers.ZoneManager,
      EmergencySystem.Servers.ResourceManager,
      EmergencySystem.Servers.NeedManager,
      EmergencySystem.Servers.FamilyRegistry,
      EmergencySystem.Servers.PetMatcher,
      EmergencySystem.Servers.ShelterManager,
      EmergencySystem.Servers.SessionSupervisor,
      EmergencySystem.Servers.SessionSupervisor.AlertBroadcaster
    ]

    opts = [strategy: :one_for_one, name: EmergencySystem.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
