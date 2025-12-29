defmodule CMS.Ingestion.AnatomyEngine do
  @moduledoc """
  The Anatomy Engine: Determines the extended anatomical type of the node and extracts physical essence.
  """
  
  require Logger
  import Bitwise

  # --- 1. Extended Node Types (The Organs) ---

  @doc """
  Determines the Extended Node Type based on Phase 1 classification and specific heuristics.
  """
  def classify_organ(triage_class, path, mime) do
    ext = Path.extname(path) |> String.downcase()
    
    cond do
      # 1. Hardware/System Interfaces
      String.starts_with?(path, "/dev/") -> :device_interface
      
      # 2. Tool Organs (Executables/Binaries)
      triage_class == :tool or 
      ext in ~w(.exe .bin .cmd .bat .com .app .vb .vbs .msi .deb .rpm .apk .jar .run) or
      mime in ["application/x-executable", "application/x-mach-binary", "application/x-java-applet", "application/x-dosexec"] ->
        :binary_organ
        
      # 3. Connective Organs (Libraries/Modules)
      triage_class == :connector or
      ext in ~w(.dll .so .dylib .sys .drv .ocx .kext .lib .a) ->
        :ligament
        
      # 4. Instruction Organs (Scripts/Source)
      triage_class == :script or
      ext in ~w(.py .pyc .pl .rb .sh .bash .zsh .js .ts .jsx .tsx .php .java .c .cpp .h .hpp .go .rs .swift .kt .scala .lua .r .ex .exs .erl .beam) ->
        :reflex_arc
        
      # 5. Configuration Organs
      is_config_file?(path) or
      ext in ~w(.conf .cfg .ini .yaml .yml .toml .list .plist) ->
        :configuration_nexus
        
      # 6. Memory & Storage Organs
      ext in ~w(.json .xml .sql .db .sqlite) or
      mime in ["application/json", "application/xml", "application/sql", "application/x-sqlite3"] ->
        :structured_memory
        
      # 7. Sensory & Archival Organs (Higher priority than general tissue)
      ext in ~w(.jpg .jpeg .png .gif .bmp .ico .svg .webp) or
      String.starts_with?(mime, "image/") ->
        :visual_cortex
        
      ext in ~w(.mp3 .wav .ogg) or
      String.starts_with?(mime, "audio/") ->
        :auditory_nerve
        
      ext in ~w(.mp4 .mov .avi .mkv) or
      String.starts_with?(mime, "video/") ->
        :sensory_nexus

      ext in ~w(.zip .tar .gz .bz2 .7z .rar .iso .img) or
      mime in ["application/zip", "application/x-tar", "application/gzip", "application/x-7z-compressed", "application/x-rar"] ->
        :encapsulated_cortex
        
      ext in ~w(.pdf .doc .docx .xls .xlsx .ppt .pptx) or
      mime in ["application/pdf", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"] ->
        :archival_memory

      ext in ~w(.ttf .otf .woff .woff2) or String.starts_with?(mime, "font/") ->
        :typographic_matrix

      # 8. General Tissue (Data/Config) - Fallback for Text
      ext in ~w(.txt .csv .tsv .md .markdown .htm .html .css .scss) or
      String.starts_with?(mime, "text/") ->
        if ext == ".log", do: :pulsing_vein, else: :semantic_tissue

      true -> :tissue_sample
    end
  end
  
  defp is_config_file?(path) do
    String.contains?(path, "/etc/") or 
    String.match?(path, ~r/(\.conf|\.cfg|\.ini|\.yaml|\.yml|\.toml|\.list|\.plist)$/) or
    Path.basename(path) in ["sys.config", "runtime.exs", "config.exs", "mix.exs"]
  end

  # --- 2. Metabolism (The Heartbeat) ---

  @doc """
  Classifies every node based on its expected metabolic rate.
  - :static_bone -> Rare changes (Binaries, Configs)
  - :fluid_blood -> Constant flux (Logs, Cache, Temp)
  """
  def classify_metabolism(path, triage_class) do
    filename = Path.basename(path) |> String.downcase()
    
    cond do
      # 1. Explicit Bone types always win (Stability)
      triage_class in [:tool, :connector] -> :static_bone
      is_config_file?(path) -> :static_bone
      triage_class == :script -> :static_bone

      # 2. Blood Nodes (High Metabolic Flux) - Checked only if not Bone
      String.ends_with?(filename, [".log", ".tmp", ".cache", "-wal", ".journal", ".swp"]) or 
      String.contains?(path, ["/tmp/", "/var/log/", "/var/cache/", "/run/", "/proc/", "/sys/"]) or
      String.match?(filename, ~r/^[0-9]+$/) -> 
        :fluid_blood

      # 3. Default to Bone
      true -> :static_bone
    end
  end

  # --- 2. The Anatomical Ledger (The Medical Record) ---

  @doc """
  Extracts the 'Essence' of the file: Permissions, Ownership, Flags.
  Returns map of DataTail fields.
  """
  def extract_essence(path) do
    case File.stat(path) do
      {:ok, stat} ->
        %{
          permissions: extract_permissions(stat),
          ownership: extract_ownership(stat),
          immutable_flags: extract_flags(path), # Mock or requires specific OS tools
          genetic_provenance: trace_provenance(path, stat)
        }
      {:error, _} ->
        %{
          permissions: %{}, ownership: %{}, immutable_flags: [], genetic_provenance: %{}
        }
    end
  end

  defp extract_permissions(stat) do
    mode = stat.mode
    %{
      user: mode_to_rwx(Bitwise.band(mode, 0o700) >>> 6),
      group: mode_to_rwx(Bitwise.band(mode, 0o070) >>> 3),
      other: mode_to_rwx(Bitwise.band(mode, 0o007))
    }
  end
  
  defp mode_to_rwx(bits) do
    r = if Bitwise.band(bits, 4) != 0, do: "r", else: "-"
    w = if Bitwise.band(bits, 2) != 0, do: "w", else: "-"
    x = if Bitwise.band(bits, 1) != 0, do: "x", else: "-"
    "#{r}#{w}#{x}"
  end
  
  defp extract_ownership(stat) do
    # In a real generic system, we might shell out to `id -nu` to get names.
    # For now, we store UIDs.
    %{
      uid: stat.uid,
      gid: stat.gid
    }
  end
  
  defp extract_flags(_path) do
    # Would run `lsattr` on Linux or `attrib` on Windows.
    # Placeholder for Phase 3.
    []
  end
  
  # --- 3. Genetic Provenance & Virtual Nodes ---
  
  defp trace_provenance(path, stat) do
    # Heuristic: Identify origin land
    origin = if stat.uid == 0, do: :root_system, else: :user_land
    
    # Identify creator context
    creator = 
      cond do
        String.starts_with?(path, ["/usr", "/bin", "/lib", "/sbin"]) -> :installer
        String.starts_with?(path, "/home") -> :user
        origin == :root_system -> :system_process
        true -> :unknown
      end
      
    %{
      origin: origin,
      creator: creator,
      # Mock package tracing
      package: if(creator == :installer, do: "system_base", else: nil)
    }
  end

  @doc """
  Identifies potential Virtual Nodes associated with this file.
  Returns a list of Virtual Node specifications.
  """
  def spawn_virtuals(path, essence) do
    %{uid: uid, gid: gid} = essence.ownership
    owner_name = Map.get(essence.ownership, :owner_name, "user_#{uid}")

    # 1. Identity Node (Owner)
    identities = [
      {:identity, uid, owner_name},
      {:group_identity, gid, "group_#{gid}"}
    ]
    
    # 2. Package Node (Path-driven)
    packages = 
      cond do
        String.starts_with?(path, ["/usr", "/bin", "/lib"]) ->
          [{:package, essence.genetic_provenance[:package] || "system_base"}]
        true -> []
      end
    
    identities ++ packages
  end
end
