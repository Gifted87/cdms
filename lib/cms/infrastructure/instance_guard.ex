defmodule CMS.Infrastructure.InstanceGuard do
  @moduledoc """
  Ensures only one ACMS instance accesses the Data Directory at a time.
  Implements the "Git-Lock" mechanism using a `running.pid` file.
  """
  use GenServer
  require Logger

  @pid_filename "running.pid"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Synchronously checks and acquires the lock.
  Must be called before Mnesia starts.
  """
  def guard_entry do
    data_dir = Application.get_env(:acn_cms, :data_root)
    # Ensure dir exists (Runtime.exs does it, but double check?)
    case acquire_lock(data_dir) do
      :ok -> :ok
      {:error, reason} ->
        Logger.critical("[InstanceGuard] Startup Aborted: #{reason}")
        # Build in a small delay to ensure log flushes if we are about to crash hard?
        :timer.sleep(100)
        raise "INSTANCE GUARD: #{reason}"
    end
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    data_dir = Application.get_env(:acn_cms, :data_root)

    case acquire_lock(data_dir) do
      :ok ->
        Logger.info("[InstanceGuard] Lock acquired on #{data_dir}")
        {:ok, %{data_dir: data_dir}}

      {:error, reason} ->
        Logger.critical("[InstanceGuard] Failed to acquire lock: #{reason}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    release_lock(state.data_dir)
  end

  defp acquire_lock(dir) do
    pid_path = Path.join(dir, @pid_filename)
    my_pid = System.pid()

    if File.exists?(pid_path) do
      case File.read(pid_path) do
        {:ok, content} ->
           check_existing_lock(String.trim(content), pid_path, my_pid)
        {:error, _} ->
           {:error, :unreadable_lock_file}
      end
    else
      write_lock(pid_path, my_pid)
    end
  end

  defp check_existing_lock(old_pid_str, pid_path, my_pid) do
    case Integer.parse(old_pid_str) do
      {old_pid_int, _} ->
        # Check if it's us (Self-Healing/Re-entrant)
        my_pid_int = String.to_integer(my_pid)

        cond do
          old_pid_int == my_pid_int ->
             # It is us. We already hold the lock (from guard_entry).
             :ok

          process_alive?(old_pid_int) ->
             {:error, "Directory locked by running instance (PID #{old_pid_int})"}

          true ->
             # Dead process
             Logger.warning("[InstanceGuard] Found stale lock from dead PID #{old_pid_int}. Cleaning up.")
             write_lock(pid_path, my_pid)
        end
      :error ->
        Logger.warning("[InstanceGuard] Found invalid PID file content. Overwriting.")
        write_lock(pid_path, my_pid)
    end
  end

  defp write_lock(path, pid) do
    File.write(path, to_string(pid))
  end

  defp release_lock(dir) do
    pid_path = Path.join(dir, @pid_filename)
    # Only delete if it holds OUR pid (race condition safety? minimal locally)
    # For simplicity, we just delete it as we are the guard.
    File.rm(pid_path)
    Logger.info("[InstanceGuard] Lock released.")
  end

  # Cross-platform check is tricky in Elixir standard lib for OS PIDs.
  # System.cmd("ps", ...) or similar?
  # Erlang doesn't have a direct `os:process_exists` for arbitrary OS PIDs easily.
  # But we can try checking via system commands.
  # User is on Windows (WSL) -> essentially Linux.
  defp process_alive?(os_pid) do
    # This is a naive check that works on POSIX.
    # kill -0 <pid> returns 0 if process exists, 1 if not.
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
