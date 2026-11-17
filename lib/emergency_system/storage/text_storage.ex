defmodule EmergencySystem.Storage.TextStorage do
  @moduledoc """
  Motor de persistencia en archivos de texto plano (.txt) usando recursividad
  para serializar y reconstruir colecciones de datos del sistema.

  ## Formato

  Cada archivo empieza con una línea de comentario (`# EmergencySystem TextStorage v1 ...`)
  y luego guarda **un registro por línea**, escrito como texto Elixir legible, por ejemplo:

      %EmergencySystem.Core.Resource{code: "R001", name: "agua", quantity: 50, ...}

  Los archivos se pueden abrir y leer con cualquier editor de texto.

  ## Seguridad

  Al leer, el texto NO se ejecuta: se convierte a AST con `Code.string_to_quoted/1` y se
  reconstruye con un evaluador recursivo de lista blanca (números, cadenas, átomos, listas,
  tuplas, mapas, `MapSet`, fechas `~U[...]` y structs del namespace `EmergencySystem.*`).
  Cualquier otra expresión se descarta. Las líneas inválidas se omiten con una advertencia.

  ## Compatibilidad

  Los archivos del formato anterior (Base64 + resumen) se siguen leyendo; en el siguiente
  guardado se reescriben en el formato nuevo.

  El directorio de datos es `"data"` por defecto y se puede cambiar con
  `config :emergency_system, :data_dir, "otra/ruta"` (útil para pruebas).
  """

  require Logger

  @default_data_dir "data"
  @header "# EmergencySystem TextStorage v1 - un registro por línea (términos Elixir)"
  @struct_namespace "Elixir.EmergencySystem."

  @doc "Directorio donde se guardan los archivos de datos."
  def data_dir, do: Application.get_env(:emergency_system, :data_dir, @default_data_dir)

  @doc """
  FUNCIÓN RECURSIVA #4:
  Guarda una lista de entidades en un archivo de texto plano convirtiendo
  recursivamente cada elemento en una línea de texto legible.

  La escritura es atómica (archivo temporal + renombrado) y, si algún registro no se puede
  representar como texto (pid, función, referencia...), no se toca el archivo existente.
  """
  def save_records(filename, records) when is_binary(filename) and is_list(records) do
    path = Path.join(data_dir(), filename)

    with {:ok, lines} <- serialize_lines_recursive(records, []),
         :ok <- File.mkdir_p(data_dir()),
         {:ok, path} <- write_atomically(path, [@header, "\n" | lines]) do
      {:ok, path}
    else
      {:error, {:registro_no_serializable, _}} = error -> error
      {:error, reason} -> {:error, {:error_escritura, reason}}
    end
  end

  # Caso base de serialización recursiva
  defp serialize_lines_recursive([], acc), do: {:ok, reverse_list(acc, [])}

  # Caso recursivo: convierte el struct/mapa en una línea de texto legible
  defp serialize_lines_recursive([record | rest], acc) do
    text = encode_record(record)

    case parse_term(text) do
      {:ok, _} ->
        serialize_lines_recursive(rest, [[text, "\n"] | acc])

      :error ->
        {:error, {:registro_no_serializable, String.slice(text, 0, 80)}}
    end
  end

  defp encode_record(record) do
    inspect(record,
      limit: :infinity,
      printable_limit: :infinity,
      width: :infinity,
      pretty: false,
      charlists: :as_lists
    )
  end

  defp write_atomically(path, iodata) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, iodata),
         :ok <- File.rename(tmp, path) do
      {:ok, path}
    end
  end

  @doc """
  Lee un archivo de texto plano y reconstruye recursivamente las estructuras
  de datos originales línea por línea.
  """
  def load_records(filename) when is_binary(filename) do
    path = Path.join(data_dir(), filename)

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, ~r/\r?\n/, trim: true)
        {:ok, parse_lines_recursive(lines, detect_format(lines), filename, 1, [])}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:error_lectura, reason}}
    end
  end

  defp detect_format([first | _]) do
    if String.starts_with?(first, "# EmergencySystem TextStorage"), do: :text, else: :legacy
  end

  defp detect_format([]), do: :text

  # Caso base de lectura recursiva
  defp parse_lines_recursive([], _format, _file, _n, acc), do: reverse_list(acc, [])

  # Caso recursivo: decodifica cada línea del archivo de texto plano
  defp parse_lines_recursive([line | rest], format, file, n, acc) do
    cond do
      String.starts_with?(line, "#") ->
        parse_lines_recursive(rest, format, file, n + 1, acc)

      true ->
        case parse_line(line, format) do
          {:ok, term} ->
            parse_lines_recursive(rest, format, file, n + 1, [term | acc])

          :error ->
            Logger.warning("TextStorage: línea #{n} de #{file} inválida, se omite")
            parse_lines_recursive(rest, format, file, n + 1, acc)
        end
    end
  end

  defp parse_line(line, :text), do: parse_term(line)

  # Formato anterior: "<base64 de term_to_binary>|<resumen>"
  defp parse_line(line, :legacy) do
    with [encoded | _] <- String.split(line, "|", parts: 2),
         {:ok, binary} <- Base.decode64(encoded) do
      {:ok, :erlang.binary_to_term(binary)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Inversión recursiva propia para mantener el orden original
  defp reverse_list([], acc), do: acc
  defp reverse_list([h | t], acc), do: reverse_list(t, [h | acc])

  # --- Lector seguro: texto -> AST -> término (sin ejecutar código) ---

  defp parse_term(text) do
    case Code.string_to_quoted(text) do
      {:ok, ast} -> {:ok, build(ast)}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    :throw, :invalid_term -> :error
  end

  # Literales
  defp build(term) when is_atom(term) or is_number(term) or is_binary(term), do: term

  # Listas (incluye listas de palabras clave: [a: 1] es [{:a, 1}])
  defp build(list) when is_list(list), do: build_list(list)

  # Tuplas de 2 elementos
  defp build({left, right}), do: {build(left), build(right)}

  # Tuplas de 0, 1 o 3+ elementos
  defp build({:{}, _, elements}) when is_list(elements),
    do: elements |> build_list() |> List.to_tuple()

  # Mapas
  defp build({:%{}, _, pairs}) when is_list(pairs), do: build_pairs(pairs, %{})

  # Structs del namespace EmergencySystem.*
  defp build({:%, _, [{:__aliases__, _, parts}, {:%{}, _, pairs}]}) when is_list(parts),
    do: build_struct(parts, pairs)

  # Átomos de módulo (p. ej. EmergencySystem.Core.Zone como valor)
  defp build({:__aliases__, _, parts}) when is_list(parts), do: concat_module(parts)

  # Números negativos
  defp build({:-, _, [number]}) when is_number(number), do: -number

  # Binarios con bytes sueltos: <<255, "abc">>
  defp build({:<<>>, _, parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      byte when is_integer(byte) and byte in 0..255 -> <<byte>>
      text when is_binary(text) -> text
      _ -> throw(:invalid_term)
    end)
    |> IO.iodata_to_binary()
  end

  # MapSet.new([...])
  defp build({{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, [list]}),
    do: list |> build() |> MapSet.new()

  # Fechas: ~U[...] (DateTime), ~N[...], ~D[...], ~T[...]
  defp build({:sigil_U, _, [{:<<>>, _, [text]}, []]}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> datetime
      _ -> throw(:invalid_term)
    end
  end

  defp build({:sigil_N, _, [{:<<>>, _, [text]}, []]}) when is_binary(text),
    do: from_iso(&NaiveDateTime.from_iso8601/1, text)

  defp build({:sigil_D, _, [{:<<>>, _, [text]}, []]}) when is_binary(text),
    do: from_iso(&Date.from_iso8601/1, text)

  defp build({:sigil_T, _, [{:<<>>, _, [text]}, []]}) when is_binary(text),
    do: from_iso(&Time.from_iso8601/1, text)

  # Cualquier otra expresión (llamadas, variables, operadores...) se rechaza
  defp build(_), do: throw(:invalid_term)

  defp build_list([]), do: []
  defp build_list([head | tail]), do: [build(head) | build_list(tail)]

  defp build_pairs([], acc), do: acc
  defp build_pairs([{key, value} | rest], acc), do: build_pairs(rest, Map.put(acc, build(key), build(value)))
  defp build_pairs(_, _), do: throw(:invalid_term)

  defp build_struct(parts, pairs) do
    module = concat_module(parts)

    if allowed_struct?(module) do
      # struct/2 completa con valores por defecto los campos que falten en archivos antiguos
      struct(module, build_pairs(pairs, %{}))
    else
      throw(:invalid_term)
    end
  end

  defp concat_module(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: throw(:invalid_term)
  end

  defp allowed_struct?(module) do
    String.starts_with?(Atom.to_string(module), @struct_namespace) and
      Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 1)
  end

  defp from_iso(fun, text) do
    case fun.(text) do
      {:ok, value} -> value
      _ -> throw(:invalid_term)
    end
  end
end
