import requests

# Configuration
filepath = r"/mnt/c/Users/hp/Downloads/The ACN.txt"  # <--- Change this to your file path
url = "http://localhost:4000/api/v1/ingest/upload"

print(f"Uploading {filepath} to ACMS...")

try:
    with open(filepath, 'rb') as f:
        files = {'file': f}
        # We don't need explicit headers for agent_id here because 
        # the backend 'Crawler' defaults to 'system' privileges internally.
        response = requests.post(url, files=files)

    if response.status_code == 202:
        print("✅ Accepted! The system is now shredding and embedding the file.")
        print("Server Response:", response.json())
    else:
        print(f"❌ Failed. Status: {response.status_code}")
        print("Reason:", response.text)

except FileNotFoundError:
    print(f"❌ Error: The file '{filepath}' was not found.")