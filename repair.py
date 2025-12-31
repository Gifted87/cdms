import os

# Target file: The Physics Engine, not the Agent
file_path = "lib/crems/physics/alchemist.ex"

print(f"Recalibrating Physics in {file_path}...")

try:
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # The hardcoded limit (512MB)
    # Pattern: max_ram = 512 * 1024 * 1024
    
    target_str = "max_ram = 512 * 1024 * 1024"
    replacement_str = "max_ram = 2048 * 1024 * 1024 # Recalibrated to 2GB"

    if target_str in content:
        new_content = content.replace(target_str, replacement_str)
        
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(new_content)
            
        print("✅ Success! Alchemist recalibrated to 2GB RAM limit.")
        
    elif "max_ram = 2048" in content:
        print("⚠️  Alchemist already recalibrated.")
    else:
        # Regex fallback just in case of formatting differences
        import re
        regex = r"max_ram\s*=\s*512\s*\*\s*1024\s*\*\s*1024"
        if re.search(regex, content):
             new_content = re.sub(regex, "max_ram = 2048 * 1024 * 1024", content)
             with open(file_path, "w", encoding="utf-8") as f:
                f.write(new_content)
             print("✅ Success! Recalibrated via Regex.")
        else:
             print("❌ Error: Could not find 'max_ram' definition in Alchemist.")

except FileNotFoundError:
    print(f"❌ Error: File {file_path} not found.")