import os

# Base directory for the CDMS codebase
BASE_DIR = os.path.abspath("lib/cms")

def patch_file(file_path, search_pattern, replace_pattern):
    full_path = os.path.join(BASE_DIR, file_path)
    if not os.path.exists(full_path):
        print(f"❌ File not found: {full_path}")
        return

    with open(full_path, 'r', encoding='utf-8') as f:
        content = f.read()

    if search_pattern in content:
        new_content = content.replace(search_pattern, replace_pattern)
        with open(full_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"✅ Patched {file_path}")
    else:
        print(f"⚠️  Pattern not found in {file_path}. It might already be patched.")

# ------------------------------------------------------------------------------
# FIX: DirectoryAgent (Enable Parallelism)
# ------------------------------------------------------------------------------
# We increase max_concurrency from 1 to 5.
# This allows 5 files to be ingested simultaneously.
agent_path = "ingestion/directory_agent.ex"

# Find the serialized stream configuration
search_serial = "max_concurrency: 1, timeout: :infinity)"
# Replace with parallel configuration
replace_parallel = "max_concurrency: 5, timeout: :infinity)"

patch_file(agent_path, search_serial, replace_parallel)
