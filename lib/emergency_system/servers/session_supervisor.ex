defmodule EmergencySystem.Servers.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor para sesiones concurrentes de usuarios y proceso independiente
  con paso de mensajes puro (spawn/send/receive) para difusión de alertas.
  """
  use DynamicSupervisor

  defmodule UserSessionWorker do
    @moduledoc "Worker efímero supervisado por cada sesión activa de usuario."
    use GenServer, restart: :temporary

    def start_link(username) do
      GenServer.start_link(__MODULE__, username)
    end

    @impl true
    def init(username) do
      {:ok, %{username: username, connected_at: DateTime.utc_now(), notifications: []}}
    end

    @impl true
    def handle_info({:emergency_alert, msg}, state) do
      {:noreply, %{state | notifications: [{DateTime.utc_now(), msg} | state.notifications]}}
    end

    @impl true
    def handle_call(:get_info, _from, state), do: {:reply, state, state}
  end

  defmodule AlertBroadcaster do
    @moduledoc """
    Proceso ligero basado en primitivas puras de Elixir (spawn_link, send, receive)
    para demostrar paso de mensajes directo sin GenServer.
    """

    def start_link do
      pid = spawn_link(fn -> loop([]) end)
      Process.register(pid, __MODULE__)
      {:ok, pid}
    end

    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, []},
        type: :worker,
        restart: :permanent
      }
    end

    def subscribe(pid) when is_pid(pid) do
      send(__MODULE__, {:subscribe, pid})
    end

    def broadcast(alert_message) when is_binary(alert_message) do
      send(__MODULE__, {:broadcast, alert_message, self()})

      receive do
        {:broadcast_ack, count} -> {:ok, count}
      after
        2_000 -> {:error, :timeout}
      end
    end

    defp loop(subscribers) do
      receive do
        {:subscribe, pid} ->
          loop(Enum.uniq([pid | subscribers]))

        {:broadcast, message, caller} ->
          active_subs = Enum.filter(subscribers, &Process.alive?/1)
          Enum.each(active_subs, fn sub_pid -> send(sub_pid, {:emergency_alert, message}) end)
          send(caller, {:broadcast_ack, length(active_subs)})
          loop(active_subs)
      end
    end
  end

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_user_session(username) do
    case find_user_session(username) do
      {:ok, existing_pid} ->
        AlertBroadcaster.subscribe(existing_pid)
        {:ok, existing_pid}

      :error ->
        spec = {UserSessionWorker, username}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} ->
            AlertBroadcaster.subscribe(pid)
            {:ok, pid}

          error ->
            error
        end
    end
  end

  def stop_user_session(username) do
    case find_user_session(username) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      :error ->
        :ok
    end
  end

  def reset_sessions do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _, _} when is_pid(pid) -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      _ -> :ok
    end)

    :ok
  end

  def active_sessions_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  defp find_user_session(username) do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:error, fn
      {_, pid, _, _} when is_pid(pid) ->
        try do
          info = GenServer.call(pid, :get_info, 1_000)
          if info.username == username, do: {:ok, pid}, else: false
        catch
          :exit, _ -> false
        end

      _ ->
        false
    end)
  end
end
