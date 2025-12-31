import os
import re

# CORRECT PATH found in your codebase dump
file_path = "lib/cms/agents/node_supervisor.ex"

print(f"Patching {file_path} to ignore TrackingAgents...")

try:
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # The buggy implementation: Selects EVERYTHING (Match Spec: {_, _, _})
    bad_regex = r"Registry\.select\(CMS\.NodeRegistry,\s*\[\{\{:_,\s*:\"\$1\",\s*:_\},\s*\[\],\s*\[:\"\$1\"\]\}\]\)"
    
    # The fix: Selects ONLY keys that are BINARIES (Strings)
    # The MatchSpec means: Match {Key, PID, _}, where is_binary(Key) is true, return PID.
    good_code = 'Registry.select(CMS.NodeRegistry, [{{:"$1", :"$2", :_}, [{:is_binary, :"$1"}], [:"$2"]}])'

    if re.search(bad_regex, content):
        new_content = re.sub(bad_regex, good_code, content)
        
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(new_content)
            
        print("✅ Success! NodeSupervisor patched.")
        
    elif good_code in content:
        print("⚠️  File is already patched.")
    else:
        print("❌ Error: Could not find the Registry.select call to patch.")

except FileNotFoundError:
    print(f"❌ Error: File {file_path} NOT FOUND. Please verify the file structure manually.")