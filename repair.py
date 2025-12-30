import os
import sys

# CORRECT PATH based on your feedback
TARGET_FILE = "/home/gifted/cdms/lib/cms/agents/node_actor.ex"

def patch_node_actor():
    if not os.path.exists(TARGET_FILE):
        print(f"❌ Error: Could not find {TARGET_FILE}")
        sys.exit(1)

    print(f"Reading {TARGET_FILE}...")
    
    with open(TARGET_FILE, 'r', encoding='utf-8') as f:
        content = f.read()

    # We look for the entry point of the activation handler
    search_pattern = "if strength > 0.2 do"
    
    # We replace it with a check against the last_fired timestamp
    # 1. Get current time
    # 2. Diff against state.node.last_fired
    # 3. Only proceed if diff > 2000ms
    replacement_pattern = """# REFRACTORY PERIOD GUARD
    # Absolute Lockout: 2000ms. Stops positive feedback loops.
    now = DateTime.utc_now()
    last = state.node.last_fired || DateTime.add(now, -3600, :second)
    diff_ms = DateTime.diff(now, last, :millisecond)

    if strength > 0.2 and diff_ms > 2000 do"""

    if "REFRACTORY PERIOD GUARD" in content:
        print("⚠️  File is already patched.")
        return

    if search_pattern in content:
        new_content = content.replace(search_pattern, replacement_pattern)
        
        with open(TARGET_FILE, 'w', encoding='utf-8') as f:
            f.write(new_content)
            
        print(f"✅ Successfully patched {TARGET_FILE}")
        print("   -> Applied 2000ms loop breaker logic.")
    else:
        print(f"❌ Error: Could not find the pattern '{search_pattern}' in the file.")

if __name__ == "__main__":
    patch_node_actor()