# CDMS / CREMS — The Cognitive Digital Modelling System

A human being can navigate a massive, complex city not because he has memorised the exact coordinates of every brick, but because he understands it spatially. When he needs to find a specific building, he does not read a list of every structure in existence. He understands districts, streets, and topologies. He moves from the macro down to the micro. The human mind does not process an environment as a flat directory of data; it processes it as a spatial, interconnected topology.

So how should AI agents understand software?

If it worked like human spatial awareness, an agent looking at a codebase would see a geography — a living structure of data flows, static code, and dynamic runtime execution. But currently, agents do neither. They parse code as flat text. When they receive a massive codebase, they read it linearly. If they need to understand how a runtime memory leak affects a static frontend module, they rely on vector search or regular expressions. The agent does not understand the software because, to the agent, the software has no shape.

This is the problem CDMS and CREMS were built to solve.

## What CDMS/CREMS Is

CDMS (the Cognitive Digital Modelling System) and CREMS (the Cognitive Runtime Environment Modelling System) turn a software environment — its files and its running processes alike — into a **connectome**: a living, self-organizing network of autonomous actors, rather than a static index sitting behind a search box. Four ideas make it work:

**Every file and every process is its own actor, not a row in a table.** Each one carries a semantic identity (what it means), a body (its actual content and history), a set of typed connections to other actors, and a signal strength that determines how loudly it "speaks" during a search. There is no central index deciding what's relevant — each actor decides that for itself.

**Spreading Activation Discovery.** A query isn't matched against a database — it's broadcast to the whole network. Every actor independently checks whether the query resonates with its own identity, and if it clears its threshold, it fires: reporting itself and pulsing its neighbors, who evaluate the same question in turn. A trace of already-visited actors prevents the signal from looping forever. The result is a search that follows the actual shape of the system's connections, not just word or vector similarity.

**Hebbian Plasticity.** Actors that keep firing together in the same queries get their connection strengthened over time. The network's wiring reflects how it's actually been used, not just how it was originally structured.

**Physiological Self-Regulation.** Raw telemetry — CPU load, error rates, memory pressure — is continuously converted into a small set of normalized "feelings": agility, stress, strain, satisfaction. When enough of the network is under strain, a global inhibition signal rises and raises the firing threshold everywhere, which keeps the system from thrashing under its own activity — the software equivalent of a nervous system dialing down sensitivity when it's overwhelmed.

On top of this, a **Chrono-Stack** keeps a reverse-diff history for every actor, so any node's state can be reconstructed as it existed at any earlier moment, and a **Phantom Engine** can push a hypothetical "force" through the network to predict where a change would strain or break something before it actually happens.

## Why It Was Built

The problem is sharpest when an AI agent has to reason about a large, live system it didn't build from scratch.

Say an agent is asked to figure out why a production service just started leaking memory. The actual answer might run: a running process → the specific module it loaded → a configuration file that was edited weeks ago → a one-line commit message explaining why. None of those four things are semantically similar to each other. A vector search for "memory leak" will not surface a config diff from three weeks ago written in someone else's shorthand. Passing the agent the entire codebase and the entire process tree isn't an option either — that blows past any realistic context window the moment the environment has any real size.

CDMS/CREMS solves this by building the connection into the substrate itself, ahead of time. CDMS maps the static side — the filesystem, the source tree, the data assets — through a wavefront crawl that classifies and wires files as it expands outward. CREMS mirrors the dynamic side — the live process tree, spawning actors for running processes and wiring them by parentage and communication channel, so the model stays a live reflection of what's actually running, not a stale snapshot. An agent that asks about one point in this network can spread outward through it and land on everything structurally or causally entangled with it — the config file, the commit, the process — without ever having been told in advance that those things were related.

## Was It Successful?

CDMS/CREMS is the cognitive substrate behind **The Genesis Machine**, the project it was built to serve — the layer that gives its agents a navigable, self-updating model of both the code they're working in and the environment that code runs in. The actor-model design, the semantic partitioning of the vector space into regions, and the sharded Hebbian buffering all exist because a single, centralized index could not keep pace with a live system that is being written to and read from continuously, by many agents, at once.

## Where It's Not the Right Fit

This is not a tool to reach for by default.

Small, simple codebases that comfortably fit in one context window don't need a connectome — the overhead of standing up an actor per file outweighs anything spreading activation would add. Anything that depends on the OS-level process introspection in CREMS is Linux-only by design; it has nothing to model on other platforms. Hard real-time or high-frequency control loops are a poor fit too — propagating a signal through a graph and buffering Hebbian updates both take time that a tight, low-latency path can't spare. Anywhere strict, deterministic, order-preserving retrieval matters — a financial ledger, an ETL pipeline — the associative "fuzziness" that makes spreading activation powerful becomes a liability instead. And a one-off, short-lived environment doesn't get much out of it either: the static Genesis crawl and the Hebbian learning curve are investments that pay off over many repeated queries, not a single ad hoc lookup.

CDMS/CREMS is built for the opposite case: large, long-lived, actively-changing environments where an agent needs to feel its way to the things it didn't know to ask about.

## How to Use

### 1. Prerequisites

The system runs on the BEAM, so it needs:

- Erlang/OTP 26.0+
- Elixir 1.15+
- A Gemini 2.5 Flash Lite API key (the semantic bridge that generates embeddings)
- A Linux host (required for CREMS's native process introspection)
- Mnesia, which ships with standard OTP

### 2. Installation and Setup

```
git clone https://github.com/Gifted87/cdms.git
cd cdms
mix deps.get && mix compile
```

Configure your environment — the simplest path is a `.env` file, loaded automatically at boot:

```
cp .env.example .env
# then set GEMINI_API_KEY=your-key-here inside .env
```

Then boot the node:

```
./cdms.sh --port 4000 --mode generative --name production_node
```

Other useful variables you can set in `.env` or export directly: `LLM_PROVIDER` (`gemini` or `ollama`), `ACMS_DATA_DIR` for where the model is persisted, `ACTIVATION_THRESHOLD` to tune how easily actors fire (defaults to `0.35`), and `HEBBIAN_REINFORCEMENT_GAIN` to tune how quickly connections strengthen with use.

### 3. Building the Connectome (Genesis)

To map a static codebase or filesystem:

```
mix cdms.genesis --path /path/to/target --mode deep
```

To start the dynamic runtime swarm and begin modelling the live process tree:

```
# via the console or API
CREMS.Ingestion.RuntimeSwarm.start_genesis()
```

### 4. Talking to It via the API

Ingesting a fact:

```
curl -X POST http://localhost:4000/api/v1/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "content": "The payment service reads its retry policy from config/retry.yml.",
    "type": "text"
  }'
```

Querying it — the unified endpoint runs a three-gate triage (symbolic, nominal, semantic) before spreading activation takes over:

```
curl -X POST http://localhost:4000/api/v1/query/unified \
  -H "Content-Type: application/json" \
  -d '{
    "query": "Why would the payment service retry so aggressively?"
  }'
```

Inspecting a single actor's full state, its history, or its connections:

```
GET /api/v1/nodes/:id
GET /api/v1/nodes/:id/history
GET /api/v1/nodes/:id/edges
```

And for a live view of the network's activity as it happens — firing events, mutations, physiological state changes — connect to the WebSocket stream at `ws://localhost:4000/api/v1/events`.

### 5. Diagnostics

If query relevance starts to drift, `mix cdms.compact` re-aligns the regional indices and clears stale traces. If the connectome stops reflecting real filesystem changes, check that the LiveWire sentinel has permission to watch the project root. `test_api.sh` is included for a quick sanity check that the API layer is up and responding.

## Documentation

See the project's own architecture notes for the full breakdown of the actor schema, the physics behind the physiological metrics, and the persistence and partitioning strategy underneath all of this.

## License

Proprietary infrastructure for The Genesis Machine. Developed by Gift Braimah.
