defmodule CREMS.Ingestion.EdgeForger do
  require Logger

  @moduledoc """
  Specialized logic for OS-level introspection and relationship mapping.
  """

  @doc """
  Scans for network communication edges.
  Logic: netstat -taupn or lsof -i.
  """
  def forge_communication_edges(pid) do
    # Rigorous Implementation: Use lsof to find all active connections
    # We resolve local destinations to their respective PIDs to link nodes directly.
    try do
      {out, 0} = System.cmd("lsof", ["-nP", "-i", "-a", "-p", to_string(pid)])
      
      out
      |> String.split("\n", trim: true)
      |> Enum.drop(1) # Header
      |> Enum.map(fn line ->
        # Parse lsof -i line: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        # Name column: IP:PORT->IP:PORT (ESTABLISHED) or *:PORT (LISTEN)
        parts = String.split(line, ~r/\s+/, trim: true)
        name = List.last(parts)
        
        cond do
          # Established connection: IP:PORT->IP:PORT
          String.contains?(name, "->") ->
            [_local, remote] = String.split(name, "->")
            [remote_ip, remote_port] = parse_addr(remote)
            
            # If remote is local, try to find the PID
            target_id = 
              if remote_ip in ["127.0.0.1", "::1", "localhost"] do
                case find_pid_by_port(remote_port) do
                  nil -> "remote-#{remote_ip}:#{remote_port}"
                  target_pid -> "pid-node-#{target_pid}"
                end
              else
                "remote-#{remote_ip}:#{remote_port}"
              end
            
            {:communicates_with, target_id, :tcp, 1.0}

          # Just scanning connections here. Listening ports are handled in scan_process.
          true -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    rescue
      _ -> []
    end
  end

  defp parse_addr(addr) do
    # Handles IPv4: port and [IPv6]:port
    case Regex.run(~r/^(.*):(\d+)$/, addr) do
      [_, host, port] -> [String.replace(host, ~r/[\[\]]/, ""), String.to_integer(port)]
      _ -> [addr, 0]
    end
  end

  @doc """
  Resolves which PID is listening on a specific port.
  """
  def find_pid_by_port(port) do
    try do
      {out, 0} = System.cmd("lsof", ["-nP", "-i", "TCP:#{port}", "-sTCP:LISTEN", "-t"])
      case String.trim(out) |> String.split("\n", trim: true) do
        [pid_str | _] -> String.to_integer(pid_str)
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc """
  Scans for ports being listened on by the process.
  """
  def extract_ports(pid) do
    try do
      {out, 0} = System.cmd("lsof", ["-nP", "-p", to_string(pid), "-i", "-sTCP:LISTEN"])
      
      Regex.scan(~r/:(\d+)\s+\(LISTEN\)/, out)
      |> Enum.map(fn [_, port] -> String.to_integer(port) end)
      |> Enum.uniq()
    rescue
      _ -> []
    end
  end

  @doc """
  Scans for dependencies (e.g., shared libraries).
  Logic: /proc/[pid]/maps or lsof.
  """
  def forge_dependency_edges(pid) do
    # Scans for shared libraries (.so files) mapped to the process memory
    try do
      {out, 0} = System.cmd("lsof", ["-p", to_string(pid)])
      
      out
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.ends_with?(&1, ".so"))
      |> Enum.map(fn line ->
        # Extract the path (usually the last column)
        parts = String.split(line, ~r/\s+/, trim: true)
        path = List.last(parts)
        lib_name = Path.basename(path)
        
        # Spec: {:depends_on, target_id}
        {:depends_on, "lib-#{lib_name}"}
      end)
      |> Enum.uniq()
    rescue
      _ -> []
    end
  end

  @doc """
  Identifies parent-child relationships.
  """
  def get_parent_id(pid) do
    case read_proc_field(pid, "status", "PPid") do
      nil -> nil
      ppid_str -> String.trim(ppid_str) |> String.to_integer()
    end
  end

  @doc """
  Resolves a numeric UID to a user name.
  """
  def resolve_user(uid) do
    try do
      {out, 0} = System.cmd("id", ["-nu", to_string(uid)])
      String.trim(out)
    rescue
      _ -> to_string(uid)
    end
  end

  @doc """
  Retrieves the absolute path to the executable.
  """
  def get_executable_path(pid) do
    case File.read_link("/proc/#{pid}/exe") do
      {:ok, path} -> path
      _ -> nil
    end
  end

  @doc """
  Discovers child processes.
  """
  def get_child_pids(pid) do
    # In Linux, we can find children via 'pgrep -P [pid]' or scanning all /proc/[pid]/status
    # For now, we simulate or use a shell command.
    try do
      {out, 0} = System.cmd("pgrep", ["-P", to_string(pid)])
      out
      |> String.split("\n", trim: true)
      |> Enum.map(&String.to_integer/1)
    rescue
      _ -> []
    end
  end

  # --- Internal ---

  defp read_proc_field(pid, file, field) do
    path = "/proc/#{pid}/#{file}"
    if File.exists?(path) do
      File.read!(path)
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        if String.starts_with?(line, field) do
          [_, val] = String.split(line, ":", parts: 2)
          val
        else
          nil
        end
      end)
    else
      nil
    end
  end
end
