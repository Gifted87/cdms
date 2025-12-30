defmodule CREMS.Ingestion.IdentityFactory do
  @moduledoc """
  Generates deterministic natural_language_facts and metadata for modelled processes.
  """

  @doc """
  Generates a fact string based on process metadata.
  """
  def generate_fact(%{binary_name: bin, user: user, args: args, ports: ports}) do
    args_str = if args == "", do: "with no arguments", else: "with arguments [#{args}]"
    port_str = if Enum.empty?(ports), do: "no open ports", else: "listening on ports #{inspect(ports)}"
    "Runtime process #{bin} owned by #{user}, running #{args_str}, #{port_str}."
  end

  def generate_fact(%{binary_name: bin, user: user}) do
    "Runtime process #{bin} owned by #{user}."
  end

  def generate_fact(%{is_erlang: true, registered_name: name, initial_call: call}) do
    name_str = if name, do: "registered as :#{name}", else: "unregistered"
    "Erlang process #{name_str}, initial call: #{inspect(call)}."
  end

  @doc """
  Generates semantic tags.
  """
  def generate_tags(%{is_erlang: true, registered_name: name}) do
    tags = ["erlang", "runtime_node", "process"]
    if name, do: [Atom.to_string(name) | tags], else: tags
  end

  def generate_tags(%{binary_name: bin, user: user}) do
    [bin, user, "runtime_node", "process"]
    |> Enum.map(&String.downcase/1)
  end
end
