defmodule EmergencySystem.Servers.FamilyRegistry do
  @moduledoc """
  GenServer para localizar personas afectadas y gestionar mensajes entre familiares.
  """
  use GenServer

  alias EmergencySystem.Core.Person
  alias EmergencySystem.Core.Person.FamilyMessage
  alias EmergencySystem.Servers.ZoneManager
  alias EmergencySystem.Storage.TextStorage

  @people_file "people.txt"
  @messages_file "family_messages.txt"

  # --- API Cliente ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def report_person(document, name, age, zone, status \\ :reportada) do
    GenServer.call(__MODULE__, {:report_person, document, name, age, zone, status})
  end

  def update_person_status(document, new_status, new_zone \\ nil) do
    GenServer.call(__MODULE__, {:update_status, document, new_status, new_zone})
  end

  def find_person(query) do
    GenServer.call(__MODULE__, {:find_person, query})
  end

  def send_family_message(sender, recipient_doc, content) do
    GenServer.call(__MODULE__, {:send_message, sender, recipient_doc, content})
  end

  def list_family_messages(recipient_doc) do
    GenServer.call(__MODULE__, {:list_messages, recipient_doc})
  end

  def mark_message_delivered(message_id) do
    GenServer.call(__MODULE__, {:mark_delivered, message_id})
  end

  def list_people do
    GenServer.call(__MODULE__, :list_people)
  end

  def reset_state do
    GenServer.call(__MODULE__, :reset_state)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_) do
    {:ok, people_list} = TextStorage.load_records(@people_file)
    {:ok, msg_list} = TextStorage.load_records(@messages_file)

    people_map = Map.new(people_list, fn %Person{document: doc} = p -> {doc, p} end)
    msg_map = Map.new(msg_list, fn %FamilyMessage{id: id} = m -> {id, m} end)

    {:ok, %{people: people_map, messages: msg_map}}
  end

  @impl true
  def handle_call({:report_person, doc, name, age, zone, status}, _from, state) do
    case Map.get(state.people, doc) do
      nil ->
        id = "P" <> String.pad_leading(Integer.to_string(map_size(state.people) + 1), 3, "0")

        case Person.new(id, doc, name, age, zone, status) do
          {:ok, person} ->
            new_people = Map.put(state.people, doc, person)
            new_state = %{state | people: new_people}
            ZoneManager.link_entity(person.zone, :reports, person.id)
            persist_people(new_people)
            {:reply, {:ok, person}, new_state}

          error ->
            {:reply, error, state}
        end

      %Person{} = existing ->
        case Person.update_status(existing, status, zone) do
          {:ok, updated} ->
            new_people = Map.put(state.people, doc, updated)
            new_state = %{state | people: new_people}
            ZoneManager.link_entity(updated.zone, :reports, updated.id)
            persist_people(new_people)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:update_status, doc, new_status, new_zone}, _from, state) do
    case Map.get(state.people, doc) do
      nil ->
        {:reply, {:error, :persona_no_encontrada}, state}

      %Person{} = person ->
        case Person.update_status(person, new_status, new_zone) do
          {:ok, updated} ->
            new_people = Map.put(state.people, doc, updated)
            new_state = %{state | people: new_people}
            persist_people(new_people)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:find_person, query}, _from, state) when is_binary(query) do
    case Map.get(state.people, query) do
      %Person{} = exact ->
        {:reply, {:ok, exact}, state}

      nil ->
        q_down = String.downcase(query)

        matches =
          state.people
          |> Map.values()
          |> Enum.filter(fn %Person{name: n, zone: z, status: s} ->
            String.contains?(String.downcase(n), q_down) or
              String.downcase(z) == q_down or
              Atom.to_string(s) == q_down
          end)

        {:reply, {:ok, matches}, state}
    end
  end

  @impl true
  def handle_call({:send_message, sender, recipient_doc, content}, _from, state) do
    msg_id = "M" <> String.pad_leading(Integer.to_string(map_size(state.messages) + 1), 3, "0")

    case FamilyMessage.new(msg_id, sender, recipient_doc, content) do
      {:ok, msg} ->
        new_msgs = Map.put(state.messages, msg_id, msg)
        new_state = %{state | messages: new_msgs}
        persist_messages(new_msgs)
        {:reply, {:ok, msg}, new_state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_messages, recipient_doc}, _from, state) do
    msgs =
      state.messages
      |> Map.values()
      |> Enum.filter(&(&1.recipient_doc == recipient_doc))

    {:reply, msgs, state}
  end

  @impl true
  def handle_call({:mark_delivered, message_id}, _from, state) do
    case Map.get(state.messages, message_id) do
      nil ->
        {:reply, {:error, :mensaje_no_encontrado}, state}

      %FamilyMessage{} = msg ->
        case FamilyMessage.mark_delivered(msg) do
          {:ok, updated} ->
            new_msgs = Map.put(state.messages, message_id, updated)
            new_state = %{state | messages: new_msgs}
            persist_messages(new_msgs)
            {:reply, {:ok, updated}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call(:list_people, _from, state) do
    {:reply, Map.values(state.people), state}
  end

  @impl true
  def handle_call(:reset_state, _from, _state) do
    persist_people(%{})
    persist_messages(%{})
    {:reply, :ok, %{people: %{}, messages: %{}}}
  end

  defp persist_people(map), do: TextStorage.save_records(@people_file, Map.values(map))
  defp persist_messages(map), do: TextStorage.save_records(@messages_file, Map.values(map))
end
