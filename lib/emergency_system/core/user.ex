defmodule EmergencySystem.Core.User do
  @moduledoc """
  Representa un usuario del sistema de emergencias con control de acceso basado en roles
  y registro inmutable de actividad.

  La contraseña NUNCA se guarda en texto plano: el campo `:password` almacena una cadena
  con el formato `sha256$iteraciones$sal$hash`. Los usuarios antiguos guardados con
  contraseña en claro se siguen aceptando y se migran a hash en su primer inicio de sesión.
  """

  import Bitwise

  @valid_roles [:ciudadano, :voluntario, :coordinador, :administrador]

  @hash_prefix "sha256"
  @iterations 10_000

  # Permisos por rol. El administrador puede ejecutar cualquier operación.
  @permissions %{
    coordinador: [
      :register_user,
      :register_zone,
      :add_sector,
      :add_attention_point,
      :register_need,
      :update_need_status,
      :assign_resource,
      :register_resource,
      :add_stock,
      :transfer_resource,
      :register_shelter,
      :register_entry,
      :register_exit,
      :link_shelter,
      :report_person,
      :find_person,
      :send_family_message,
      :mark_message_delivered,
      :report_pet,
      :match_pets,
      :confirm_match,
      :broadcast_alert,
      :view_summary
    ],
    voluntario: [
      :register_need,
      :update_need_status,
      :report_person,
      :find_person,
      :send_family_message,
      :mark_message_delivered,
      :report_pet,
      :match_pets,
      :confirm_match,
      :register_entry,
      :register_exit,
      :link_shelter,
      :view_summary
    ],
    ciudadano: [
      :register_need,
      :report_person,
      :find_person,
      :send_family_message,
      :report_pet
    ]
  }

  @enforce_keys [:username, :password, :full_name, :role, :zone]
  defstruct [
    :username,
    :password,
    :full_name,
    :role,
    :zone,
    connected: false,
    activity_log: []
  ]

  @type role :: :ciudadano | :voluntario | :coordinador | :administrador
  @type t :: %__MODULE__{
          username: String.t(),
          password: String.t(),
          full_name: String.t(),
          role: role(),
          zone: String.t(),
          connected: boolean(),
          activity_log: list({DateTime.t(), String.t()})
        }

  @doc "Lista de roles válidos del sistema."
  def valid_roles, do: @valid_roles

  @doc "Operaciones permitidas para un rol (`:all` para el administrador)."
  def permissions(:administrador), do: :all
  def permissions(role), do: Map.get(@permissions, role, [])

  @doc "Crea un nuevo usuario validando campos y rol. La contraseña se guarda con hash y sal."
  def new(username, password, full_name, role, zone)
      when is_binary(username) and is_binary(password) and is_binary(full_name) and
             role in @valid_roles and is_binary(zone) do
    if String.trim(username) == "" or String.trim(password) == "" do
      {:error, :credenciales_vacias}
    else
      user = %__MODULE__{
        username: String.trim(username),
        password: hash_password(password),
        full_name: String.trim(full_name),
        role: role,
        zone: String.trim(zone),
        connected: false,
        activity_log: [{DateTime.utc_now(), "Usuario registrado"}]
      }

      {:ok, user}
    end
  end

  def new(_, _, _, role, _) when role not in @valid_roles,
    do: {:error, {:rol_invalido, role, @valid_roles}}

  def new(_, _, _, _, _), do: {:error, :datos_usuario_invalidos}

  @doc """
  Valida la contraseña y cambia el estado a conectado.

  Si el usuario venía de un archivo antiguo con la contraseña en claro,
  se reemplaza por su hash al autenticarse.
  """
  def authenticate(%__MODULE__{password: stored} = user, input_password)
      when is_binary(input_password) do
    cond do
      hashed?(stored) and verify_hash(stored, input_password) ->
        {:ok, connect(user)}

      not hashed?(stored) and secure_compare(stored, input_password) ->
        {:ok, connect(%{user | password: hash_password(input_password)})}

      true ->
        {:error, :credenciales_invalidas}
    end
  end

  def authenticate(%__MODULE__{}, _), do: {:error, :credenciales_invalidas}

  @doc "Desconecta al usuario."
  def disconnect(%__MODULE__{} = user) do
    {:ok,
     %{user | connected: false}
     |> log_activity("Sesión cerrada")}
  end

  @doc "Registra una acción en el historial del usuario (inmutable)."
  def log_activity(%__MODULE__{activity_log: log} = user, action) when is_binary(action) do
    %{user | activity_log: [{DateTime.utc_now(), action} | log]}
  end

  @doc "Verifica si el rol del usuario tiene permiso para ejecutar una operación."
  def authorized?(%__MODULE__{connected: false}, _operation), do: {:error, :usuario_no_conectado}

  def authorized?(%__MODULE__{role: :administrador}, _operation), do: :ok

  def authorized?(%__MODULE__{role: role}, operation) do
    if operation in permissions(role) do
      :ok
    else
      {:error, {:no_autorizado, role, operation}}
    end
  end

  # --- Privadas ---

  defp connect(%__MODULE__{} = user) do
    %{user | connected: true} |> log_activity("Conexión iniciada")
  end

  defp hashed?(stored), do: String.starts_with?(stored, @hash_prefix <> "$")

  defp hash_password(password) do
    salt = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{@hash_prefix}$#{@iterations}$#{salt}$#{derive(password, salt, @iterations)}"
  end

  defp verify_hash(stored, input) do
    with [@hash_prefix, iter, salt, hash] <- String.split(stored, "$"),
         {iterations, ""} when iterations > 0 <- Integer.parse(iter) do
      secure_compare(derive(input, salt, iterations), hash)
    else
      _ -> false
    end
  end

  # Hash SHA-256 iterado con sal (sin dependencias externas).
  defp derive(password, salt, iterations) do
    1..iterations
    |> Enum.reduce("", fn _, acc -> :crypto.hash(:sha256, acc <> salt <> password) end)
    |> Base.encode16(case: :lower)
  end

  # Comparación en tiempo constante para no filtrar información por tiempos de respuesta.
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> bor(acc, bxor(x, y)) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_, _), do: false
end
