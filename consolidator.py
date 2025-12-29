import os

def is_text_file(file_path):
    """
    Determines if a file is text or binary.
    1. Checks against a list of known binary extensions.
    2. Reads the first 1024 bytes to check for null bytes (heuristic).
    """
    # 1. Ignore specific binary extensions immediately
    binary_extensions = {
        # Images
        '.png', '.jpg', '.jpeg', '.gif', '.ico', '.svg', '.webp',
        # Compiled / Executables
        '.pyc', '.pyo', '.exe', '.dll', '.so', '.o', '.a', '.bin',
        # Archives
        '.zip', '.tar', '.gz', '.7z', '.rar',
        # Elixir / Erlang compiled
        '.beam', '.ez', '.dcd', # Added .dcd based on your logs (Mnesia)
        # Documents
        '.pdf', '.docx', '.xlsx',
        # Database
        '.db', '.sqlite', '.sqlite3'
    }
    
    _, ext = os.path.splitext(file_path)
    if ext.lower() in binary_extensions:
        return False

    # 2. Heuristic: Check for null bytes in the beginning of the file
    try:
        with open(file_path, 'rb') as f:
            chunk = f.read(1024)
            if b'\0' in chunk:
                return False  # File contains null bytes, likely binary
    except Exception:
        return False # If we can't open it, skip it

    return True

def compile_codebase_to_text(root_dir, output_file):
    """
    Recursively gathers all text files in a codebase.
    Excludes hidden folders, ignored directories, and binary files.
    """
    
    # Configuration: Directory names to ignore (exact matches)
    ignored_dirs = {
        "priv",        # <--- Added this to skip your data folder
        "_build", 
        "deps", 
        "__pycache__",
        "node_modules",
        ".git",
        ".idea",
        ".vscode",
        "venv",
        "env"
    }

    # Files to specifically ignore (exact matches)
    ignored_filenames = {
        "compiled_codebase.txt", 
        "consolidator.py",
        "package-lock.json",
        "yarn.lock"
    }

    file_count = 0

    try:
        with open(output_file, 'w', encoding='utf-8') as out_file:
            for dirpath, dirnames, filenames in os.walk(root_dir):
                # ---------------------------------------------------------
                # 1. Filter Directories
                # Remove hidden folders and ignored_dirs (like 'priv')
                # ---------------------------------------------------------
                dirnames[:] = [
                    d for d in dirnames 
                    if not d.startswith('.') and d not in ignored_dirs
                ]
                
                # Write folder header
                relative_path = os.path.relpath(dirpath, root_dir)
                
                if relative_path == ".":
                    folder_header = f"\n{'='*80}\nRoot Directory\n{'='*80}\n"
                else:
                    folder_header = f"\n{'='*80}\nFolder: {relative_path}\n{'='*80}\n"
                
                out_file.write(folder_header)
                
                for filename in filenames:
                    # -----------------------------------------------------
                    # 2. Filter Files
                    # Skip hidden files, ignored names, and binaries
                    # -----------------------------------------------------
                    if filename.startswith('.') or filename in ignored_filenames:
                        continue

                    file_path = os.path.join(dirpath, filename)

                    # Check if it looks like a text file
                    if not is_text_file(file_path):
                        continue

                    try:
                        with open(file_path, 'r', encoding='utf-8') as f:
                            file_content = f.read()
                        
                        # If successful, write to output
                        file_header = f"\n{'-'*60}\nFile: {filename}\n{'-'*60}\n"
                        out_file.write(file_header)
                        out_file.write(file_content + "\n")
                        
                        file_count += 1
                        print(f"Processed: {os.path.join(relative_path, filename)}")

                    except UnicodeDecodeError:
                        print(f"Skipped (Encoding issue): {filename}")
                    except Exception as e:
                        print(f"Skipped (Error: {e}): {filename}")

        print(f"\nSuccess! Compiled {file_count} files into {output_file}")
        
    except Exception as e:
        print(f"Critical Error: {e}")

if __name__ == "__main__":
    # Current working directory
    root_directory = os.getcwd()
    output_text_file = os.path.join(root_directory, "compiled_codebase.txt")
    
    compile_codebase_to_text(root_directory, output_text_file)