# verification_script
defmodule ExhaustiveAnatomyVerification do
  alias CMS.Ingestion.AnatomyEngine
  
  def run do
    IO.puts("\n=== Starting Exhaustive Anatomical Mapping Verification ===\n")
    
    # 1. Tool Organs
    IO.puts("--- Tool Organs (.exe, ELF, Mach-O) ---")
    check_ext(".exe", :binary_organ)
    check_ext(".bin", :binary_organ)
    check_ext(".apk", :binary_organ)
    check_ext(".jar", :binary_organ)
    check_mime("application/x-executable", :binary_organ)
    
    # 2. Connective Organs
    IO.puts("\n--- Connective Organs (.dll, .so) ---")
    check_ext(".dll", :ligament)
    check_ext(".so", :ligament)
    check_ext(".dylib", :ligament)
    check_ext(".a", :ligament)
    
    # 3. Instruction Organs (Scripts)
    IO.puts("\n--- Instruction Organs (.py, .js, .sh) ---")
    check_ext(".py", :reflex_arc)
    check_ext(".js", :reflex_arc)
    check_ext(".sh", :reflex_arc)
    check_ext(".ex", :reflex_arc)
    check_ext(".rs", :reflex_arc)
    
    # 4. Configuration Organs
    IO.puts("\n--- Configuration Organs (.conf, .yaml) ---")
    check_ext(".conf", :configuration_nexus)
    check_ext(".yaml", :configuration_nexus)
    check_ext(".ini", :configuration_nexus)
    
    # 5. Memory & Storage Organs
    IO.puts("\n--- Structured Memory (.json, .sql) ---")
    check_ext(".json", :structured_memory)
    check_ext(".sql", :structured_memory)
    check_ext(".sqlite", :structured_memory)
    
    IO.puts("\n--- Semantic Tissue (.txt, .md) ---")
    check_ext(".txt", :semantic_tissue)
    check_ext(".md", :semantic_tissue)
    check_ext(".html", :semantic_tissue)
    
    IO.puts("\n--- Pulsing Vein (.log) ---")
    check_ext(".log", :pulsing_vein)
    
    # 6. Sensory & Archival Organs
    IO.puts("\n--- Encapsulated Cortex (.zip, .tar) ---")
    check_ext(".zip", :encapsulated_cortex)
    check_ext(".tar", :encapsulated_cortex)
    check_ext(".7z", :encapsulated_cortex)
    
    IO.puts("\n--- Archival Memory (.pdf, .doc) ---")
    check_ext(".pdf", :archival_memory)
    check_ext(".docx", :archival_memory)
    
    IO.puts("\n--- Visual Cortex (.jpg, .png) ---")
    check_ext(".jpg", :visual_cortex)
    check_ext(".png", :visual_cortex)
    check_ext(".svg", :visual_cortex)
    
    IO.puts("\n--- Auditory Nerve (.mp3, .wav) ---")
    check_ext(".mp3", :auditory_nerve)
    check_ext(".wav", :auditory_nerve)
    
    IO.puts("\n--- Sensory Nexus (.mp4, .mkv) ---")
    check_ext(".mp4", :sensory_nexus)
    check_ext(".mkv", :sensory_nexus)

    IO.puts("\n--- Typographic Matrix (Fonts) ---")
    check_ext(".ttf", :typographic_matrix)
    check_ext(".woff", :typographic_matrix)

    IO.puts("\n=== Exhaustive Anatomical Mapping Complete ===\n")
  end

  defp check_ext(ext, expected) do
    # We pass :tissue as triage_class for most extensions to see if the engine correctly identifies the organ
    # For scripts, we pass :script to trigger the reflex_arc logic if needed, but the ext should work too.
    triage = cond do
      ext in ~w(.py .js .sh .ex .rs) -> :script
      ext in ~w(.exe .bin) -> :tool
      ext in ~w(.so .dll) -> :connector
      true -> :tissue
    end
    
    actual = AnatomyEngine.classify_organ(triage, "test#{ext}", "text/plain")
    if actual == expected do
      IO.puts("  #{ext} -> #{actual}: [OK]")
    else
      IO.puts("  #{ext} -> #{actual}: [FAILED] (Expected: #{expected})")
    end
  end

  defp check_mime(mime, expected) do
    actual = AnatomyEngine.classify_organ(:tissue, "file", mime)
    if actual == expected do
      IO.puts("  #{mime} -> #{actual}: [OK]")
    else
      IO.puts("  #{mime} -> #{actual}: [FAILED] (Expected: #{expected})")
    end
  end
end

ExhaustiveAnatomyVerification.run()
