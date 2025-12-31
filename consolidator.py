import os

def is_text_file(file_path):
    """
    Determines if a file is text or binary.
    1. Checks against a list of known binary extensions.
    2. Reads the first 1024 bytes to check for null bytes (heuristic).
    """
    binary_extensions = {
        # Images
        '.png', '.jpg', '.jpeg', '.gif', '.ico', '.svg', '.webp',
        # Compiled / Executables
        '.pyc', '.pyo', '.exe', '.dll', '.so', '.o', '.a', '.bin',
        # Archives
        '.zip', '.tar', '.gz', '.7z', '.rar',
        # Elixir / Erlang compiled
        '.beam', '.ez', '.dcd',
        # Documents
        '.pdf', '.docx', '.xlsx',
        # Databases
        '.db', '.sqlite', '.sqlite3'
    }

    _, ext = os.path.splitext(file_path)
    if ext.lower() in binary_extensions:
        return False

    try:
        with open(file_path, 'rb') as f:
            if b'\0' in f.read(1024):
                return False
    except Exception:
        return False

    return True

# ----------------------------
# Exclusion Rules
# ----------------------------

SKIP_PREFIXES = (
    'verify',
    'test',
    'deps',
    'build',
    'config',
    '_',
    'memory',
    'venv',
    'priv'
)

IGNORED_DIRS = {
    '__pycache__',
    'node_modules',
    '.git',
    '.idea',
    '.vscode',
    'env'
}

IGNORED_FILES = {
    'compiled_codebase.txt',
    'consolidator.py',
    'package-lock.json',
    'yarn.lock'
}


def starts_with_skipped_prefix(name: str) -> bool:
    return name.lower().startswith(SKIP_PREFIXES)


# ----------------------------
# Main Compiler
# ----------------------------

def compile_codebase_to_text(root_dir, output_file):
    file_count = 0

    with open(output_file, 'w', encoding='utf-8') as out_file:
        for dirpath, dirnames, filenames in os.walk(root_dir):

            # Filter directories in-place
            dirnames[:] = [
                d for d in dirnames
                if not d.startswith('.')
                and d not in IGNORED_DIRS
                and not starts_with_skipped_prefix(d)
            ]

            relative_path = os.path.relpath(dirpath, root_dir)
            header = (
                f"\n{'=' * 80}\n"
                f"{'Root Directory' if relative_path == '.' else f'Folder: {relative_path}'}"
                f"\n{'=' * 80}\n"
            )
            out_file.write(header)

            for filename in filenames:
                if (
                    filename.startswith('.')
                    or filename in IGNORED_FILES
                    or starts_with_skipped_prefix(filename)
                ):
                    continue

                file_path = os.path.join(dirpath, filename)

                if not is_text_file(file_path):
                    continue

                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()

                    out_file.write(
                        f"\n{'-' * 60}\n"
                        f"File: {filename}\n"
                        f"{'-' * 60}\n"
                    )
                    out_file.write(content + '\n')

                    file_count += 1
                    print(f"Processed: {os.path.join(relative_path, filename)}")

                except UnicodeDecodeError:
                    print(f"Skipped (encoding): {filename}")
                except Exception as e:
                    print(f"Skipped ({e}): {filename}")

    print(f"\nSuccess. Compiled {file_count} files into {output_file}")


if __name__ == '__main__':
    root = os.getcwd()
    output = os.path.join(root, 'compiled_codebase.txt')
    compile_codebase_to_text(root, output)
