# verification_script
defmodule TriageVerification do
  alias CMS.Ingestion.TriageProtocol

  # Exhaustive Lists from Spec
  @tool_exts ~w(.exe .bin .cmd .bat .com .app .vb .vbs .msi .deb .rpm .apk .jar .run)
  @connector_exts ~w(.dll .so .dylib .sys .drv .ocx .kext .lib .a)
  @instruction_exts ~w(.py .pyc .pl .rb .sh .bash .zsh .js .ts .jsx .tsx .php .java .c .cpp .h .hpp .go .rs .swift .kt .scala .lua .r .ex .exs .erl .beam)
  @tissue_data_exts ~w(.txt .json .xml .yaml .yml .toml .ini .conf .cfg .csv .tsv .log .sql .db .sqlite .htm .html .css .scss .md .markdown)
  @tissue_media_exts ~w(.zip .tar .gz .bz2 .7z .rar .iso .img .pdf .doc .docx .xls .xlsx .ppt .pptx .jpg .jpeg .png .gif .bmp .ico .svg .webp .mp3 .wav .ogg .mp4 .mov .avi .mkv)

  def run do
    IO.puts("\n=== Starting Exhaustive Triage Verification ===\n")

    test_dir = "/tmp/triage_verification_#{System.unique_integer()}"
    File.mkdir_p!(test_dir)

    try do
      # 1. Exhaustive Extension Heuristics
      IO.puts("--- Phase 1: Extension Heuristics (Exhaustive) ---")
      
      check_group("Tool", @tool_exts, :tool, test_dir)
      check_group("Connector", @connector_exts, :connector, test_dir)
      check_group("Instruction", @instruction_exts, :script, test_dir)
      check_group("Tissue (Data)", @tissue_data_exts, :tissue, test_dir)
      check_group("Tissue (Media)", @tissue_media_exts, :tissue, test_dir)

      # 2. Exhaustive Deep Scan (Magic Bytes)
      IO.puts("\n--- Phase 2: Deep Scan (Exhaustive Magic Bytes) ---")
      
      signatures = [
        {"ELF", <<0x7F, 0x45, 0x4C, 0x46, 0::size(64)>>, :tool},
        {"PE", <<0x4D, 0x5A, 0::size(64)>>, :tool},
        {"Mach-O (FE)", <<0xFE, 0xED, 0xFA, 0xCE, 0::size(64)>>, :tool},
        {"Mach-O (CF)", <<0xFE, 0xED, 0xFA, 0xCF, 0::size(64)>>, :tool},
        {"Java Class", <<0xCA, 0xFE, 0xBA, 0xBE, 0::size(64)>>, :tool},
        {"PDF", <<0x25, 0x50, 0x44, 0x46, 0::size(64)>>, :tissue},
        {"ZIP", <<0x50, 0x4B, 0x03, 0x04, 0::size(64)>>, :tissue},
        {"GZIP", <<0x1F, 0x8B, 0::size(32)>>, :tissue},
        {"7z", <<0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0::size(64)>>, :tissue},
        {"RAR", <<0x52, 0x61, 0x72, 0x21, 0::size(64)>>, :tissue},
        {"PNG", <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0::size(64)>>, :tissue},
        {"JPEG", <<0xFF, 0xD8, 0xFF, 0::size(64)>>, :tissue},
        {"GIF", <<0x47, 0x49, 0x46, 0x38, 0::size(64)>>, :tissue},
        {"BMP", <<0x42, 0x4D, 0::size(64)>>, :tissue},
        {"Shebang", "#!/bin/sh\n", :script},
        {"Null Bytes", <<0, 0, 0, 0>>, :raw_data}
      ]

      Enum.each(signatures, fn {name, magic, expected} ->
        path = Path.join(test_dir, "magic_test_#{name |> String.replace(" ", "_")}")
        assert_identify(path, magic, expected, name)
      end)

      # 3. Conflict & Special Logic
      IO.puts("\n--- Phase 3: Conflict & Special Logic ---")
      
      # Connector (DLL) + PE Signature -> Connector
      assert_identify(Path.join(test_dir, "test.dll"), <<0x4D, 0x5A, 0::size(64)>>, :connector, "DLL with PE")
      
      # Connector (SO) + ELF Signature -> Connector
      assert_identify(Path.join(test_dir, "test.so"), <<0x7F, 0x45, 0x4C, 0x46, 0::size(64)>>, :connector, "SO with ELF")

      # Executable Text
      exec_path = Path.join(test_dir, "executable.txt")
      File.write!(exec_path, "text")
      File.chmod!(exec_path, 0o755)
      val = TriageProtocol.identify(exec_path)
      if val == {:ok, :tool} do
         IO.puts("Executable Text: PASSED")
      else
         IO.puts("Executable Text: FAILED -> Got #{inspect(val)}")
      end

      IO.puts("\n=== Verification Complete ===\n")
      
    after
      File.rm_rf!(test_dir)
    end
  end

  defp check_group(group_name, extensions, expected_class, test_dir) do
    IO.puts("Checking #{group_name} (#{length(extensions)} extensions):")
    
    results = Enum.map(extensions, fn ext ->
      path = Path.join(test_dir, "test#{ext}")
      # Use neutral content that won't trigger magic bytes unless it's nulls
      content = "neutral content" 
      case assert_identify_quiet(path, content, expected_class) do
        :ok -> :ok
        {:error, got} -> {:error, ext, got}
      end
    end)
    
    failures = Enum.filter(results, fn res -> res != :ok end)
    
    if Enum.empty?(failures) do
      IO.puts("  ALL PASSED")
    else
      IO.puts("  FAILURES DETECTED:")
      Enum.each(failures, fn {:error, ext, got} -> 
        IO.puts("    #{ext}: Expected #{inspect(expected_class)}, Got #{inspect(got)}")
      end)
    end
  end

  defp assert_identify_quiet(path, content, expected) do
    File.write!(path, content)
    case CMS.Ingestion.TriageProtocol.identify(path) do
      {:ok, ^expected} -> :ok
      other -> {:error, other}
    end
  end

  defp assert_identify(path, content, expected, context) do
    File.write!(path, content)
    case CMS.Ingestion.TriageProtocol.identify(path) do
      {:ok, ^expected} -> IO.puts("  #{context}: PASSED")
      other -> IO.puts("  #{context}: FAILED -> Expected #{inspect(expected)}, Got #{inspect(other)}")
    end
  end
end

TriageVerification.run()
