defmodule CMS.Ingestion.MimeGuard do
  @moduledoc """
  Determines if a file is safe to ingest (Text/Code) or rejected (Binary).
  """

  @allowlist ~w(.txt .md .markdown .ex .exs .py .js .ts .json .html .css .yml .yaml .toml .gitignore .dockerfile .sh .bat .ps1)
  
  @doc """
  Checks if the file at the given path is safe to ingest.
  """
  def check(path) when is_binary(path) do
    with :ok <- check_extension(path),
         :ok <- check_content(path) do
      :ok
    end
  end

  defp check_extension(path) do
    ext = Path.extname(path) |> String.downcase()
    if ext in @allowlist do
      :ok
    else
      {:error, {:unsupported_extension, ext}}
    end
  end

  defp check_content(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result = read_header(file)
        File.close(file)
        result
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_header(file) do
    case IO.binread(file, 1024) do
      :eof -> :ok # Empty file is safe
      data when is_binary(data) ->
        if String.contains?(data, <<0>>) do
          {:error, :binary_file}
        else
          :ok
        end
      {:error, reason} -> {:error, reason}
    end
  end
end
