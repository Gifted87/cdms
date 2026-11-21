# Cognitive Digital Modeling System (CDMS)

CDMS is an Elixir/OTP service for indexing and querying relationships in a codebase or other local data. It stores nodes and their temporal history in Mnesia, builds symbolic and semantic links during ingestion, and exposes query and ingestion interfaces over HTTP. A companion Python service generates text embeddings.

This repository contains an evolving research prototype. Features and operational behavior may change; review the code and security notes before using it with important or sensitive data.

## What it provides

- File and directory ingestion through the CDMS crawler and ingestion pipeline.
- Symbolic, nominal, and semantic query paths, with node history and relationship lookups.
- A supervised Elixir application using OTP, Mnesia, Broadway, and Phoenix PubSub.
- An optional FastAPI bridge backed by `sentence-transformers` for embedding and salience requests.
- HTTP endpoints for ingestion, queries, node details, history, edges, feedback, health, and events.

## Requirements

- Erlang/OTP and Elixir (the Mix project specifies Elixir `~> 1.14`).
- Rust and Cargo for building the Rustler native code graph component.
- Python 3 for the optional embedding bridge. The bridge requires FastAPI, Uvicorn, PyTorch, and sentence-transformers.

## Build and run

Fetch dependencies and compile the Elixir application:

```sh
mix deps.get
mix compile
```

Start the application:

```sh
mix run --no-halt
```

The HTTP service defaults to port `4000`. Set `ACMS_PORT` to use another port. Data is stored under `memory_cartridges/default` by default; set `ACMS_DATA_DIR` to choose a different data directory. The launcher `cdms.sh` can start the application with a target directory as its working directory and stores its generated state in that directory's `.cdms_model/` folder:

```sh
./cdms.sh --port 4000 --mode deterministic
```

To enable semantic embeddings, install the Python bridge dependencies in a virtual environment and start the bridge separately:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install fastapi uvicorn sentence-transformers torch
python ml_bridge.py
```

The bridge loads the `all-MiniLM-L6-v2` model at startup and listens on port `5000` by default. The Elixir service expects it at `http://localhost:5000`.

## HTTP interface

The service exposes these routes under `/api/v1`:

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/ingest` | Ingest a knowledge record |
| `POST` | `/ingest/upload` | Ingest an uploaded file |
| `POST` | `/query` | Query stored knowledge |
| `POST` | `/query/unified` | Route a query through the unified query interface |
| `GET` | `/nodes/:id` | Fetch a node |
| `GET` | `/nodes/:id/history` | Fetch node history |
| `GET` | `/nodes/:id/edges` | Fetch node relationships |
| `POST` | `/nodes/:id/feedback` | Submit node feedback |
| `GET` | `/health/embedder` | Check the embedding bridge |
| `GET` | `/events` | Receive live event updates over WebSocket |

See `lib/cms/interface/cms_web.ex` for request fields and response formats.

## Data and configuration

The application persists its model in Mnesia and maintains epoch/log data beneath the configured data directory. Keep this runtime state out of source control; `.gitignore` excludes local data and generated model directories.

Configuration is read from environment variables. A local `.env` file is also loaded by `config/runtime.exs`; do not commit it. Common settings include:

- `ACMS_PORT` — HTTP port (default `4000`).
- `ACMS_DATA_DIR` — persistent data directory.
- `ACMS_NODE_NAME` — node name used by the launcher.
- `LLM_PROVIDER` and `GEMINI_API_KEYS` — provider selection and Gemini credentials.
- `CMS_ADMIN_TOKEN` — token used for administrative operations.

**Security:** This prototype has not been reviewed for production deployment. The runtime configuration contains a weak default administrative token (`admin_secret`), and the HTTP interface should not be exposed to an untrusted network. Set a unique secret in a protected environment and review route authorization, data handling, and network binding before deployment.

## Development

Run the Elixir test suite with:

```sh
mix test
```

The repository also contains standalone diagnostic and verification scripts. They are development utilities and may depend on a running local instance or generated model data.

## License

No license file is currently included. Contact the repository owner for licensing information before redistributing or incorporating this project.
