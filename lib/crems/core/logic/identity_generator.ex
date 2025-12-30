defmodule CREMS.Core.Logic.IdentityGenerator do
  @moduledoc """
  Generates immutable identity facts for CREMS Nodes.
  Strictly template-based (No LLM).
  """

  @doc """
  Generates a natural language fact string from node metadata.
  
  ## Examples
  
      iex> metadata = %{role: "postgres_worker", pid: 4096, user: "postgres", port: 5432}
      iex> CREMS.Core.Logic.IdentityGenerator.generate_fact(metadata)
      "The Postgres Worker process [PID 4096] owned by user 'postgres' listening on port 5432."
  """
  def generate_fact(metadata) do
    role = Map.get(metadata, :role, "Unknown Agent")
    pid = Map.get(metadata, :pid, "0")
    user = Map.get(metadata, :user, "system")
    
    base_fact = "The #{snake_case_to_title(to_string(role))} process [PID #{pid}] owned by user '#{user}'"
    
    case Map.get(metadata, :port) do
      nil -> "#{base_fact}."
      port -> "#{base_fact} listening on port #{port}."
    end
  end

  defp snake_case_to_title(str) do
    str
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
