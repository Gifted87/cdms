defmodule CMS.Interface.Console do
  @moduledoc """
  A user-friendly helper for running queries directly from the IEx console.
  Pretty-prints node summaries, concepts, and content.
  """

  require Logger

  @doc """
  Runs a query and prints a formatted, human-readable report.
  
  ## Usage:
      iex> CMS.Interface.Console.query("What is the purpose of the GeminiBridge?")
  """
  @doc """
  Fetches and prints details for ALL nodes currently in the system.
  """
  def list_all do
    IO.puts("\n[ACMS Global Node Audit] -------------------------------------")
    
    uuids = :mnesia.dirty_all_keys(:nodes_table)
    IO.puts("Total Nodes: #{length(uuids)}\n")

    uuids
    |> Enum.with_index(1)
    |> Enum.each(fn {uuid, idx} ->
      case :mnesia.dirty_read(:nodes_table, uuid) do
        [{:nodes_table, ^uuid, _ph, _pid, _head, body, tail, _stack, _prov, _ant}] ->
          # Construct a temporary node map for the printer
          node = %{body: body, tail: tail}
          print_node_details(node, idx, nil)
        
        [{:nodes_table, ^uuid, _ph, _pid, _head, body, tail, _stack, _prov}] ->
          node = %{body: body, tail: tail}
          print_node_details(node, idx, nil)

        _ ->
          IO.puts("#{idx}. [ERROR] Could not read node #{uuid}")
      end
    end)
    
    IO.puts("-----------------------------------------------------------\n")
    :ok
  end

  def query(query_string, opts \\ []) do
    IO.puts("\n[ACMS Query] -----------------------------------------------")
    IO.puts("Query: \"#{query_string}\"")
    
    start_time = System.monotonic_time(:millisecond)
    
    case CMS.QueryTriage.execute(query_string, opts) do
      {:ok, mode, results} ->
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time
        
        IO.puts("Mode:  #{inspect(mode)}")
        IO.puts("Time:  #{duration}ms")
        IO.puts("Nodes: #{length(results)}")
        IO.puts("-----------------------------------------------------------\n")

        if Enum.empty?(results) do
          IO.puts("No matching nodes found.")
        else
          results
          |> Enum.with_index(1)
          |> Enum.each(fn {result, idx} -> print_result(result, idx) end)
        end

      {:error, reason} ->
        IO.puts("Search FAILED: #{inspect(reason)}")
    end
    
    IO.puts("\n-----------------------------------------------------------")
    :ok
  end

  defp print_result(%{node: node, score: score}, idx) do
    # Semantic result format
    print_node_details(node, idx, score)
  end

  defp print_result(node, idx) do
    # Symbolic/Nominal result format
    print_node_details(node, idx, nil)
  end

  defp print_node_details(node, idx, score) do
    path = node.body.data_ledger.physical_symlink
    summary = node.body.data_head.summary
    concepts = node.body.data_head.concepts
    content = node.body.data_body

    score_str = if score, do: " [Score: #{Float.round(score, 4)}]", else: ""
    
    IO.puts("#{idx}. #{path}#{score_str}")
    IO.puts("   Summary:  #{summary}")
    IO.puts("   Concepts: #{inspect(concepts)}")
    
    if content do
      # Print first 500 characters of content with indentation
      formatted_content = 
        if is_binary(content) do
          content 
          |> String.slice(0, 500) 
          |> String.replace("\n", "\n      ")
        else
          inspect(content, pretty: true)
          |> String.slice(0, 500)
          |> String.replace("\n", "\n      ")
        end
        
      IO.puts("   Content Preview:")
      IO.puts("      #{formatted_content}...")
    else
      IO.puts("   Content:  [Shallow/Binary]")
    end
    IO.puts("")
  end
end
