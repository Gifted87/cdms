defmodule CMS.Persistence.Identity do
  @moduledoc """
  Manages the identity.lock file, which serves as the "Signature" of the last machine
  that successfully wrote to the data directory.
  
  Used to detect when data has been moved to a new host (Alien Data), triggering rehydration.
  """
  
  @lock_file_name "identity.lock"
  
  defstruct [:node_name, :architecture, :version, :data_dir_path]
  
  @type t :: %__MODULE__{
    node_name: atom(),
    architecture: binary(),
    version: binary(),
    data_dir_path: binary()
  }

  @doc """
  Checks the lock file against the current system identity.
  Returns:
  - :ok -> Identity matches (Fast Boot).
  - :mismatch -> Identity differs (Rehydrate).
  - :missing -> No lock file (Fresh Init).
  """
  def check_lock do
    path = lock_file_path()
    
    if File.exists?(path) do
      case File.read(path) do
        {:ok, binary} ->
           try do
             stored_identity = :erlang.binary_to_term(binary)
             if identities_match?(stored_identity, current_identity()) do
               :ok
             else
               :mismatch
             end
           rescue
             _ -> :mismatch # Corrupt lock file -> treated as mismatch
           end
        {:error, _} -> :missing
      end
    else
      :missing
    end
  end
  
  @doc """
  Writes the current identity to the lock file. All Rehydration/Boot processes must call this
  once they are ready to own the data.
  """
  def sign_lock do
    path = lock_file_path()
    identity = current_identity()
    binary = :erlang.term_to_binary(identity)
    File.write!(path, binary)
    :ok
  end
  
  def delete_lock do
    File.rm(lock_file_path())
  end

  def current_identity do
    %__MODULE__{
      node_name: Node.self(),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      version: Application.spec(:acn_cms, :vsn) |> to_string(),
      # We also track the absolute path. If the folder moves on the SAME machine,
      # Mnesia might still be confused if it uses absolute paths internally.
      data_dir_path: Path.absname(Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store")
    }
  end
  
  defp identities_match?(stored, current) do
    # We strictly check Architecture and Node Name (Mnesia requirement).
    # We can be lenient on Version (Migration logic handles that elsewhere).
    stored.node_name == current.node_name and 
    stored.architecture == current.architecture
  end
  
  defp lock_file_path do
    # Lock file sits at the root of the data store parent (Rehydrator philosophy)
    # If mnesia_dir is "priv/data/mnesia_store", lock is at "priv/data/identity.lock"
    mnesia_dir = Application.get_env(:mnesia, :dir) || "priv/data/mnesia_store"
    root_data_dir = Path.dirname(mnesia_dir)
    Path.join(root_data_dir, @lock_file_name)
  end
end
