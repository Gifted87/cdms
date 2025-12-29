defmodule CMS.Ingestion.TriageProtocol do
  @moduledoc """
  The Triage Protocol (Phase 1): Identification & Classification.
  
  Implements a multi-layered identification protocol:
  1. Primary Glance: Extension Heuristics (Comprehensive)
  2. Deep Scan: Binary Signatures (DNA) & Shebangs (Expanded)
  3. Functional Promotion: Execute Bit Check
  """

  require Logger

  @doc """
  Identifies the type of a file based on extension, content (magic bytes), and metadata.
  
  Returns one of:
  - `{:ok, :tool}`: Executables, binaries, archives acting as tools (.jar)
  - `{:ok, :connector}`: Shared libraries/objects
  - `{:ok, :script}`: Source code/Scripts
  - `{:ok, :tissue}`: Data, Config, Media, Archives
  - `{:ok, :raw_data}`: Unknown binary data
  - `{:error, reason}`: File access error
  """
  def identify(path) do
    with {:ok, stat} <- File.stat(path) do
      # 1. Primary Glance
      classification = classify_by_extension(path)
      
      # 2. Deep Scan (Refines classification)
      classification = refine_with_deep_scan(path, classification)
      
      # 3. Functional Promotion
      final_classification = check_functional_promotion(stat, classification)
      
      {:ok, final_classification}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Phase 1: The Primary Glance (Extension Heuristics) ---

  defp classify_by_extension(path) do
    ext = Path.extname(path) |> String.downcase()
    
    cond do
      ext in ~w(.exe .bin .cmd .bat .com .app .vb .vbs .msi .deb .rpm .apk .jar .run) -> :tool
      
      ext in ~w(.dll .so .dylib .sys .drv .ocx .kext .lib .a) -> :connector
      
      ext in ~w(.py .pyc .pl .rb .sh .bash .zsh .js .ts .jsx .tsx .php .java .c .cpp .h .hpp .go .rs .swift .kt .scala .lua .r .ex .exs .erl .beam) -> :script
      
      ext in ~w(.txt .json .xml .yaml .yml .toml .ini .conf .cfg .csv .tsv .log .sql .db .sqlite .htm .html .css .scss .md .markdown) -> :tissue
      
      # Media/Archive tissue
      ext in ~w(.zip .tar .gz .bz2 .7z .rar .iso .img .pdf .doc .docx .xls .xlsx .ppt .pptx .jpg .jpeg .png .gif .bmp .ico .svg .webp .mp3 .wav .ogg .mp4 .mov .avi .mkv) -> :tissue
      
      true -> :tissue
    end
  end

  # --- Phase 2: The Deep Scan (The "DNA" Test) ---

  defp refine_with_deep_scan(path, current_classification) do
    # Read first 256 bytes for signatures
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        header = IO.binread(file, 256)
        File.close(file)
        
        case header do
          :eof -> current_classification
          data when is_binary(data) -> detect_magic(data, current_classification)
          {:error, _} -> current_classification
        end
        
      {:error, _} -> current_classification
    end
  end

  defp detect_magic(header, current_class) do
    cond do
      # --- Tool/Connector Signatures ---
      
      # ELF (Linux) 7F 45 4C 46
      match?(<<0x7F, 0x45, 0x4C, 0x46, _::binary>>, header) -> 
        if current_class == :connector, do: :connector, else: :tool

      # PE (Windows) 4D 5A
      match?(<<0x4D, 0x5A, _::binary>>, header) -> 
        if current_class == :connector, do: :connector, else: :tool
        
      # Mach-O (macOS) FE ED FA CE / FE ED FA CF (32/64 bit)
      match?(<<0xFE, 0xED, 0xFA, 0xCE, _::binary>>, header) or match?(<<0xFE, 0xED, 0xFA, 0xCF, _::binary>>, header) ->
        if current_class == :connector, do: :connector, else: :tool

      # Java Class CA FE BA BE
      match?(<<0xCA, 0xFE, 0xBA, 0xBE, _::binary>>, header) -> :tool 

      # --- Tissue Signatures (Archives/Media) ---
      # These effectively confirm it's NOT raw_data, but specific Tissue.
      # If current_class was :tissue (from extension), this confirms it.
      # If current_class was unknown/raw, this sets it to :tissue.

      # PDF 25 50 44 46
      match?(<<0x25, 0x50, 0x44, 0x46, _::binary>>, header) -> :tissue
      
      # ZIP 50 4B 03 04
      match?(<<0x50, 0x4B, 0x03, 0x04, _::binary>>, header) -> :tissue
      
      # GZIP 1F 8B
      match?(<<0x1F, 0x8B, _::binary>>, header) -> :tissue
      
      # 7z 37 7A BC AF 27 1C
      match?(<<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, _::binary>>, header) -> :tissue
      
      # RAR 52 61 72 21
      match?(<<0x52, 0x61, 0x72, 0x21, _::binary>>, header) -> :tissue
      
      # PNG 89 50 4E 47 0D 0A 1A 0A
      match?(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, header) -> :tissue
      
      # JPEG FF D8 FF
      match?(<<0xFF, 0xD8, 0xFF, _::binary>>, header) -> :tissue
      
      # GIF 47 49 46 38
      match?(<<0x47, 0x49, 0x46, 0x38, _::binary>>, header) -> :tissue
      
      # BMP 42 4D
      match?(<<0x42, 0x4D, _::binary>>, header) -> :tissue

      # --- Script Signatures ---

      # Shebang #!
      match?(<<0x23, 0x21, _::binary>>, header) -> :script

      # --- Fallbacks ---

      # Null Check (Raw Data)
      String.contains?(header, <<0>>) -> 
        if current_class == :connector, do: :connector, else: :raw_data

      true -> current_class
    end
  end

  # --- Phase 3: The Functional Promotion ---

  defp check_functional_promotion(%File.Stat{mode: mode}, current_classification) do
    is_executable = (Bitwise.band(mode, 0o100) != 0) or 
                    (Bitwise.band(mode, 0o010) != 0) or 
                    (Bitwise.band(mode, 0o001) != 0)

    cond do
      is_executable and current_classification == :tissue -> :tool
      is_executable and current_classification == :raw_data -> :tool
      true -> current_classification
    end
  end
end
