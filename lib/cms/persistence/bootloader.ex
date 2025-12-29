defmodule CMS.Persistence.Bootloader do
  require Logger
  alias CMS.Persistence.Identity
  alias CMS.Recovery.Rehydrator

  @doc """
  The synchronous "Gatekeeper" run at application startup.
  """
  def run do
    Logger.info("CMS Bootloader: Checking Persistence Integrity...")
    
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
end
