import os

# The file that failed compilation
file_path = "lib/cms/ingestion/file_ingestion_task.ex"

print(f"Repairing syntax error in {file_path}...")

try:
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # The issue: content = ... else: \"[BINARY OMITTED]\"
    # The fix:   content = ... else: "[BINARY OMITTED]"
    
    # We replace the escaped version with the clean version
    bad_syntax = r'else: \"[BINARY OMITTED]\"'
    good_syntax = r'else: "[BINARY OMITTED]"'
    
    if bad_syntax in content:
        new_content = content.replace(bad_syntax, good_syntax)
        
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
            
        print("✅ Syntax fixed! Backslashes removed.")
    else:
        print("⚠️  Could not find the specific syntax error pattern. Please check line 111 manually.")

except FileNotFoundError:
    print(f"❌ Error: File {file_path} not found.")