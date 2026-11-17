defmodule EmergencySystem.Servers.UserRegistry do
  @moduledoc """
  GenServer encargado de la autenticación, registro automático y auditoría de usuarios.
  """
  use GenServer

  alias EmergencySystem.Core.User
  alias EmergencySystem.Storage.TextStorage

  @storage_file "users.txt"

  # --- API Cliente ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register_user(username, password, full_name, role, zone) do
    GenServer.call(__MODULE__, {:register, username, password, full_name, role, zone})
  end

  @doc "Conecta un usuario; si no existe, lo registra automáticamente (Requisito 1.4.2)."
  def connect(username, password, role \\ :ciudadano, zone \\ "general") do
    GenServer.call(__MODULE__, {:connect, username, password, role, zone})
  end

  def disconnect(username) do
    GenServer.call(__MODULE__, {:disconnect, username})
  end

  def authorize(username, operation) do
    GenServer.call(__MODULE__, {:authorize, username, operation})
  end

  def log_action(username, action) do
    GenServer.cast(__MODULE__, {:log_action, username, action})
  end

  def get_user(username) do
    GenServer.call(__MODULE__, {:get_user, username})
  end

  def list_users do
    GenServer.call(__MODULE__, :list_users)
  end

  @doc "Usuarios con sesión activa."
  def connected_users do
    GenServer.call(__MODULE__, :connected_users)
  end

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_) do
    {:ok, records} = TextStorage.load_records(@storage_file)

    # Al reiniciar el sistema nadie puede seguir conectado: se limpia el estado de sesión.
    state =
      Map.new(records, fn %User{username: u} = user -> {u, %{user | connected: false}} end)

    {:ok, state}
  end

  @impl true
  def handle_call({:register, username, password, full_name, role, zone}, _from, state) do
    key = normalize(username)

    if Map.has_key?(state, key) do
      {:reply, {:error, :usuario_ya_existe}, state}
    else
      case User.new(username, password, full_name, role, zone) do
        {:ok, user} ->
          new_state = Map.put(state, user.username, user)
          persist(new_state)
          {:reply, {:ok, user}, new_state}

        error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:connect, username, password, role, zone}, _from, state) do
    key = normalize(username)

    case Map.get(state, key) do
      nil ->
        # Si no existe -> registro automático y conexión inmediata
        with {:ok, new_user} <- User.new(username, password, username, role, zone),
             {:ok, connected_user} <- User.authenticate(new_user, password) do
          new_state = Map.put(state, connected_user.username, connected_user)
          persist(new_state)
          {:reply, {:ok, :registrado_y_conectado, connected_user}, new_state}
        else
          error -> {:reply, error, state}
        end

      %User{} = existing_user ->
        case User.authenticate(existing_user, password) do
          {:ok, connected_user} ->
            new_state = Map.put(state, key, connected_user)
            persist(new_state)
            {:reply, {:ok, :conectado, connected_user}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:disconnect, username}, _from, state) do
    key = normalize(username)

    case Map.get(state, key) do
      nil ->
        {:reply, {:error, :usuario_no_existe}, state}

      %User{} = user ->
        {:ok, disconnected} = User.disconnect(user)
        new_state = Map.put(state, key, disconnected)
        persist(new_state)
        {:reply, {:ok, disconnected}, new_state}
    end
  end

  @impl true
  def handle_call({:authorize, username, operation}, _from, state) do
    case Map.get(state, normalize(username)) do
      nil -> {:reply, {:error, :usuario_no_encontrado}, state}
      %User{} = user -> {:reply, User.authorized?(user, operation), state}
    end
  end

  @impl true
  def handle_call({:get_user, username}, _from, state) do
    case Map.get(state, normalize(username)) do
      nil -> {:reply, {:error, :usuario_no_encontrado}, state}
      user -> {:reply, {:ok, user}, state}
    end
  end

  @impl true
  def handle_call(:list_users, _from, state) do
    {:reply, Map.values(state), state}
  end

  @impl true
  def handle_call(:connected_users, _from, state) do
    {:reply, state |> Map.values() |> Enum.filter(& &1.connected), state}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    persist(%{})
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_cast({:log_action, username, action}, state) do
    key = normalize(username)

    case Map.get(state, key) do
      nil ->
        {:noreply, state}

      %User{} = user ->
        updated = User.log_activity(user, action)
        new_state = Map.put(state, key, updated)
        persist(new_state)
        {:noreply, new_state}
    end
  end

  defp normalize(username) when is_binary(username), do: String.trim(username)
  defp normalize(other), do: other

  defp persist(state) do
    TextStorage.save_records(@storage_file, Map.values(state))
  end
end
