# verify_deterministic_aggregator.exs

# Mocking modules if necessary, but here we can just require the app context
# For simplicity, we assume we run this via 'mix run'

path = "/home/gifted/cdms/lib/cms/ingestion/deterministic_aggregator.ex"
content = File.read!(path)
mime = "text/x-elixir"

IO.puts "--- Testing Deterministic Aggregator (Scaled) ---"
summary = CMS.Ingestion.DeterministicAggregator.aggregate(path, content, mime)

IO.puts "\nGenerated Summary Blob:\n"
IO.puts summary

# Basic Assertions (7 Dimensions)
required = ["[INTENT]:", "[STRUCTURE]:", "[IMPORTS]:", "[COMMENTS]:", "[KEYWORDS]:", "[GEOGRAPHY]:", "[ANATOMY]:"]
missing = Enum.filter(required, fn r -> not String.contains?(summary, r) end)

if missing == [] do
  IO.puts "\nSUCCESS: All 7 dimensions present."
else
  IO.puts "\nFAILURE: Missing dimensions: #{inspect(missing)}"
  exit({:error, :missing_dimensions})
end

# Check Elixir specific extraction
if String.contains?(summary, "Module: CMS.Ingestion.DeterministicAggregator") do
  IO.puts "SUCCESS: Elixir AST structure correctly extracted."
else
  IO.puts "FAILURE: AST structure extraction failed."
  exit({:error, :ast_failure})
end

# --- Test 2: Python Heuristics (Imports + Comments) ---
py_content = """
\"\"\"
This is a Python module docstring.
\"\"\"
import os
import sys
# This is a line comment about auth
class AuthController:
    def login(self):
        pass
"""
IO.puts "\n--- Testing Python Extraction ---"
summary_py = CMS.Ingestion.DeterministicAggregator.aggregate("auth.py", py_content, "text/x-python")
IO.puts summary_py

if String.contains?(summary_py, "import os") or String.contains?(summary_py, "os") do
   IO.puts "SUCCESS: Python imports extracted."
else 
   IO.puts "FAILURE: Python imports failed."
end

if String.contains?(summary_py, "This is a line comment about auth") do
   IO.puts "SUCCESS: Python comments extracted."
else
   IO.puts "FAILURE: Python comments failed."
end

# --- Test 3: Java/C-Style Heuristics ---
java_content = """
/**
 * Main application class.
 */
package com.example;
import java.util.List;

// Helper function for sorting
public class Main {
    public void main(String[] args) {
        // inline comment
    }
}
"""
IO.puts "\n--- Testing Java Extraction ---"
summary_java = CMS.Ingestion.DeterministicAggregator.aggregate("Main.java", java_content, "text/x-java")
IO.puts summary_java

if String.contains?(summary_java, "java.util.List") do
    IO.puts "SUCCESS: Java imports extracted."
end

if String.contains?(summary_java, "Helper function for sorting") do
    IO.puts "SUCCESS: Java comments extracted."
end

# --- Test 4: Markdown Heuristics ---
md_content = "# Project Genesis\n## Overview\nThis is the plan."
IO.puts "\n--- Testing Markdown Extraction ---"
summary_md = CMS.Ingestion.DeterministicAggregator.aggregate("README.md", md_content, "text/markdown")
IO.puts summary_md
if String.contains?(summary_md, "Project Genesis") and String.contains?(summary_md, "Overview") do
    IO.puts "SUCCESS: Markdown headers extracted."
end

# --- Test 5: JSON Heuristics ---
json_content = "{\"id\": 1, \"status\": \"active\", \"metadata\": {}}"
IO.puts "\n--- Testing JSON Extraction ---"
summary_json = CMS.Ingestion.DeterministicAggregator.aggregate("data.json", json_content, "application/json")
IO.puts summary_json
if String.contains?(summary_json, "id") and String.contains?(summary_json, "status") do
    IO.puts "SUCCESS: JSON keys extracted."
end

# --- Test 6: CSV Heuristics ---
csv_content = "name,email,role\nAlice,alice@web.com,admin"
IO.puts "\n--- Testing CSV Extraction ---"
summary_csv = CMS.Ingestion.DeterministicAggregator.aggregate("users.csv", csv_content, "text/csv")
IO.puts summary_csv
if String.contains?(summary_csv, "name, email, role") do
    IO.puts "SUCCESS: CSV columns extracted."
end

# --- Test 7: Archive Heuristics ---
IO.puts "\n--- Testing Archive Extraction ---"
summary_zip = CMS.Ingestion.DeterministicAggregator.aggregate("source.zip", <<0,1,2,3>>, "application/zip")
IO.puts summary_zip
if String.contains?(summary_zip, "Compressed archive artifact.") and String.contains?(summary_zip, "source, zip") do
    IO.puts "SUCCESS: Archive identified correctly."
end

# --- Test 8: Package Heuristics ---
IO.puts "\n--- Testing Package Extraction ---"
summary_deb = CMS.Ingestion.DeterministicAggregator.aggregate("app_v1.0.deb", <<0,1,2,3>>, "application/vnd.debian.binary-package")
IO.puts summary_deb
if String.contains?(summary_deb, "Executable or distribution package.") and String.contains?(summary_deb, "app, deb") do
    IO.puts "SUCCESS: Package identified correctly."
end
