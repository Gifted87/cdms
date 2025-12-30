defmodule CMS.Persistence.Bootloader do
  require Logger
  alias CMS.Persistence.Identity
  alias CMS.Recovery.Rehydrator

  # Table Definitions
  @table_name :epoch_log_index
  @nodes_table :nodes_table
  @vector_index :vector_index

  def run do
    Logger.info("CMS Bootloader: Checking Persistence Integrity...")
    
    # Pre-flight: Ensure Schema and Tables exist
    ensure_schema_and_tables()

    case Identity.check_lock() do
      :ok ->
        if schema_damaged?() do
          Logger.warning("CMS Bootloader: Identity Verified but Mnesia Schema is DAMAGED or INCOMPATIBLE.")
          rehydrate_and_sign()
        else
          Logger.info("CMS Bootloader: Identity Verified. Fast Boot initiated.")
        end
        :ok
        
      :mismatch ->
        Logger.warning("CMS Bootloader: ALIEN DATA DETECTED! (Architecture/Node Mismatch).")
        rehydrate_and_sign()
        :ok
        
      :missing ->
        if data_exists?() do
          Logger.warning("CMS Bootloader: Data directory exists but identity.lock is missing.")
          rehydrate_and_sign()
        else
          Logger.info("CMS Bootloader: No existing data found. Assuming Fresh Init.")
          Identity.sign_lock()
        end
        :ok
    end
  end

  defp rehydrate_and_sign do
    Logger.warning("CMS Bootloader: Initiating Emergency REHYDRATION.")
    Rehydrator.rehydrate()
    Identity.sign_lock()
  end

  defp schema_damaged? do
    mnesia_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store"
    schema_file = Path.join(mnesia_dir, "schema.DAT")
    
    if File.exists?(schema_file) do
       # Paranoid check: Can we open this schema as a DETS file?
       # Mnesia schema is internally a DETS file. If this returns :badarg or :error, 
       # Mnesia will crash upon start.
       case :dets.open_file(:boot_probe, [{:file, String.to_charlist(schema_file)}, {:repair, false}, {:access, :read}]) do
         {:ok, _} -> 
            :dets.close(:boot_probe)
            false
         _ -> true
       end
    else
      false
    end
  end

  defp data_exists? do
    mnesia_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store"
    case File.ls(mnesia_dir) do
      {:ok, files} when files != [] -> true
      _ -> false
    end
  end

  @doc """
  Ensures Mnesia schema and tables exist. 
  Safe to call multiple times (idempotent).
  """
  def ensure_schema_and_tables do
    Logger.info("CMS Bootloader: Ensuring Schema and Tables...")
    
    # 1. Get Directory from Config
    raw_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store"
    mnesia_dir = if is_binary(raw_dir), do: String.to_charlist(raw_dir), else: raw_dir

    # 2. Ensure directory
    File.mkdir_p!(to_string(mnesia_dir))
    Application.put_env(:mnesia, :dir, mnesia_dir)
    
    nodes = [Node.self()]

    # 3. Stop Mnesia to perform cleanup/creation if needed
    :mnesia.stop()

    # 4. Create Schema
    case :mnesia.create_schema(nodes) do
      :ok -> Logger.info("Mnesia schema created.")
      {:error, {_, {:already_exists, _}}} -> :ok
      error -> Logger.error("Mnesia create_schema failed: #{inspect(error)}")
    end

    # 5. Start Mnesia (temporarily to create tables)
    :mnesia.start()

    # 6. Create Tables
    create_table_if_missing(@table_name, [attributes: [:id, :start_time, :end_time, :file_path], disc_copies: nodes])
    create_table_if_missing(@nodes_table, [attributes: [:uuid, :path_hash, :parent_uuid, :head_data, :body_data, :tail_data, :chrono_stack, :provenance, :antenna_data], disc_copies: nodes])
    create_table_if_missing(@vector_index, [attributes: [:id, :vector], disc_copies: nodes, type: :ordered_set])

    # 7. Stop Mnesia so Application can start it cleanly
    :mnesia.stop()
  end

  defp create_table_if_missing(name, opts) do
    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} -> Logger.info("Mnesia table #{name} created.")
      {:aborted, {:already_exists, _}} -> :ok
      other -> Logger.error("Mnesia create_table #{name} failed: #{inspect(other)}")
    end
  end
end
