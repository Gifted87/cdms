# Distributed Semantic Modelling & Runtime Observation Ecosystem

**Developed by Gift Braimah for the Autonomous Intelligence Community.**
*Licensed under the MIT License. (c) 2026 CDMS & CREMS.*

## 1. System Engineering Philosophy & Architecture of the Cognitive Substrate

The Cognitive Digital Modelling System (CDMS) and the Cognitive Runtime Environment Modelling System (CREMS) represent a unified architectural framework for the creation of high-fidelity, autonomous digital environments. The core engineering objective is the transmutation of static project resources and dynamic runtime processes into a **Distributed Cognitive Substrate**. This substrate is not a traditional centralized index; it is an ensemble of autonomous actors that evaluate, fire, and evolve independently, providing a navigable "connectome" for AI agents.

### 1.1 The Axiom of Autonomy
In this architecture, every discrete digital entity—whether a source-code file, a persistent data asset, or an active operating system process—is instantiated as a self-contained, identifiable actor within a high-concurrency network. These actors operate according to a decentralized paradigm where global system understanding emerges from local interactions rather than a centralized query engine. Each actor is responsible for its own state management, semantic evaluation, and metabolic regulation.

### 1.2 The Unified Model of Digital Identity
Digital identity within the substrate is determined by a content-addressable logic. By deriving entity identifiers from the cryptographic hash of their structural "truth" and provenance metadata, the system ensures that identical knowledge assets map to the same address. This provides a "Fixed Identity" for the digital atoms, allowing the system to maintain a stable topology even as behavioral relationships and synaptic weights evolve over time. This separation between the "Fact" (Truth) and the "Relationship" (Synapse) is fundamental to the system's neuroplasticity and its ability to reconcile overlapping knowledge sources.

---

## 2. The Autonomous Actor Schema: The Quad-Partite Entity

Every actor within the substrate adheres to a rigorous quad-partite internal schema designed to maximize both symbolic utility and semantic query-ability across the distributed network.

### 2.1 The Control Layer (Semantic Identity)
The control layer houses the high-dimensional vector embeddings that represent the entity's functional intent and conceptual identity. These embeddings are generated through a "Cognitive Bridge" that summarizes the entity's purpose in natural language before vectorization. By storing these embeddings locally within each actor, the system enables decentralized evaluation. When a query context is broadcast across the network, the actor itself performs the cosine similarity calculation to determine if its semantic identity is a relevant match for the request.

### 2.2 The Body (Persistent Content & History)
The body of the actor contains the raw data or "Truth" of the entity. Depending on the ingestion strategy, this may be a deep representation (raw content) or a shallow reference (metadata only). Crucially, the body contains the **Chrono-Stack**—an immutable ledger of the entity's evolution. Every state mutation is captured as a reverse-diff snapshot, allowing the system to perform high-resolution "Temporal Forensics" by reconstructing the state of any entity as it existed at a specific point in the system's history.

### 2.3 The Connectivity Matrix (The Synaptic Tail)
Relationships are represented by typed and weighted edges stored in the connectivity matrix. This matrix defines the entity's position within the three primary system networks:
- **The Structural Network**: Hierarchical parenting and membership relationships (e.g., directory structures or process trees).
- **The Functional Network**: Cross-entity dependencies, imports, and communication channels (e.g., process-to-socket links).
- **The Semantic Network**: Associative links discovered through Hebbian priming and scatter-gather protocols.

### 2.4 The Signal Modulation Layer (The Antenna)
The antenna modulates the strength of the signals emitted by the actor during propagation cycles. It determines the "Gain" of the node, which is dynamically adjusted based on the entity's intrinsic salience, its historical activity frequency, and its current "Physiological State." This layer ensures that critical configuration or high-traffic logic receives greater signal amplification than transient or secondary assets.

---

## 3. Spreading Activation Dynamics & Cognitive Self-Regulation

Interaction with the digital connectome is driven by **Spreading Activation Signals**. This mechanism facilitates associative discovery by propagating pulses of energy through the typed edges of the connectivity matrix.

### 3.1 Autonomous Firing & Threshold Logic
The system's search capabilities are decentralized. When a query is initiated, the system broadcasts a "Context Descriptor" to all actors. Each actor autonomously performs an evaluation:
1. **Relevance Calculation**: The actor computes the cosine similarity between the query vector and its internal semantic identity.
2. **Threshold Modulation**: The firing threshold ($T_{adj}$) is dynamically calculated. This threshold is influenced by the global system inhibition signal and the node's individual internal state.
3. **The Firing Event**: If the calculated relevance exceeds the threshold, the actor "fires." It reports its ID and state to a search coordinator and emits a pulse to all its neighbors in the connectivity matrix.

### 3.2 Synaptic Propagation & Trace-Based Loop Prevention
When an actor fires, it initiates a propagation sequence. Pulses travel along edges, with their strength modulated by the edge weight and the source actor's gain. To prevent infinite loops in the highly interconnected graph, the system utilizes a **Trace-Based Guard**. Every pulse carries a "Trace" of all actors it has already visited. If an actor receives a pulse and finds its own ID in the trace, it inhibits the signal, ensuring that cognitive activity naturally terminates once its associative path is exhausted.

### 3.3 Hebbian Optimization & Synaptic Plasticity
The connectivity of the substrate is plastic and evolves based on usage patterns through **Regional Hebbian Reinforcement**. When two actors are frequently co-activated in a single query session, the system assumes a functional relationship and strengthens the link by increasing the edge weight.

---

## 4. Telemetry-to-Physics Transmutation: The Logic of Feeling

The observation layer of the system transmutes raw telemetry into **Standardized Physiological Feelings**. This provides a common "Physics" for interpreting the health and performance of diverse digital entities.

### 4.1 The Transmutation Formulas
The system uses an "Alchemist" logic to convert raw metrics (e.g., CPU load, memory usage, I/O wait, message queue length) into normalized indicators:
- **Agility (Responsiveness)**: Derived from the ratio of operational throughput to the resource cost incurred. High agility represents efficient, non-blocked operation.
- **Stress (The Struggle)**: Calculated using a sigmoid-squashed combination of immediate load and error rates. $Stress = Sigmoid((Load * 0.5) + (ErrorRate * 2.0))$.
- **Strain (Cumulative Load)**: Calculated based on memory saturation and I/O wait factors. It represents the degree to which a node is pushed toward its capacity limits.
- **Satisfaction (Operational Success)**: A ratio of successful operations to total events.

### 4.2 Homeostasis & Global Inhibition
To prevent "Cognitive Overload," the system maintains a **Global Inhibition Factor**. This factor is derived from real-time monitoring of message queue congestion and system-wide load. As the inhibition signal increases, the firing threshold across all actors rises proportionally, dampening the spread of activation and ensuring system stability.

---

## 5. The Predictive Manifold: High-Resolution Force Simulations

The **Phantom Engine** provides the system with predictive foresight by simulating hypothetical scenarios within a "Shadow Substrate" (The Phantom Manifold).

### 5.1 Force Vector Propagation
Simulation is initiated by applying a **Force Vector** representing a theoretical pressure. The engine propagates this force through the model's links, calculating the predicted outcome for each affected node based on its unique biology-neutral physics parameters.

### 5.2 Elasticity and Saturation Modeling
- **Elasticity Coefficient**: Every node possesses an elasticity factor derived from its historical behavior. Brittle nodes are more likely to fail under pressure, while elastic nodes absorb it. The coefficient follows the formula: $Elasticity = 1.0 / (1.0 - (StrainDelta * Stress))$.
- **Saturation Prediction**: The engine predicts the "Saturation Point" where operational physics will fail, identifying cascading failure points across the distributed architecture.

---

## 6. Distributed State Persistence & Temporal Forensics

The framework implements a robust, immutable persistence architecture that treats history as a fundamental asset.

### 6.1 Epoch-Based Journaling & The Chronicle
Every material change to the connectome is appended to a sequential **Epoch Log**. This append-only design ensures that the system's "Chronicle" is never overwritten. Periodically, logs are rotated into a distributed registry, providing high-throughput writes for real-time updates and efficient random-access for rehydration.

### 6.2 Reverse-Diff State Reconstruction
The **Temporal Query Engine** enables time-travel within the model. By replaying reverse-diffs from the Chrono-Stack starting from the most recent full snapshot, the system can reconstruct the entire state of any node or sub-graph at any microsecond in history.

---

## 7. Autonomous Swarm Dynamics: Environmental Discovery

The construction and maintenance of the connectome are handled by **Autonomous Exploration Swarms**.

### 7.1 The Static Wavefront (Project Discovery)
During "Genesis," a static exploration swarm maps the filesystem using a **Wavefront Algorithm**. It expands recursively, spawning specialized agents to classify assets, generate semantic summaries, and instantiate actors. A "Membership Hash" mechanism enables incremental updates, reducing re-ingestion overhead.

### 7.2 The Dynamic Runtime Swarm (Environment Reflection)
The dynamic modeller traverses the operating system's process tree and the virtual machine's process space. It identifies active PIDs and BEAM processes, transmuting them into nodes and wiring them based on parent-child relationships and communication channels, creating a live reflection of the running environment.

---

## 8. Ingestion Intelligence & The Exclusion Protocols

To maintain a focused connectome, the system employs several layers of filtering and classification intelligence.

### 8.1 The Triage Protocol
Assets undergo a multi-layer triage:
1. **The Primary Glance**: A heuristic check of file extensions.
2. **The Deep Scan (DNA Check)**: Analysis of "Magic Bytes" and binary signatures.
3. **Functional Promotion**: Analysis of system-level metadata (e.g., execution bits) to identify "Tools."

### 8.2 The Exclusion Cortex & Cognitive Swamp PREVENTION
The **Exclusion Cortex** prevents "Cognitive Swamp" by employing path-aware filtering to drop build artifacts and noise. It also performs a "Semantic Gate" check on generated summaries, ensuring the connectome contains only coherent, high-confidence semantic data.

---

## 9. Forensic Autopsy & The Ghost Lifecycle

Process termination is treated as a transition in the node lifecycle.

### 9.1 The Necrosis Signal
Upon termination, the system receives a **Necrosis Signal**, activating the **Autopsy Protocol**. This captures the final physiological state, exit code, and a forensic buffer of the last several telemetry ticks, archiving the data in the node's history before decommissioning the active actor.

### 9.2 Scavenging & Ghost Archival
Terminated entities transition into a "Ghost State"—an archival representation. A periodic **Ghost Scavenger** scans for ghosts whose retention period has passed, performs a final log archival, and removes them from the active registry.

---

## 10. Advanced Scalability: Semantic Partitioning & Regional Indexing

To operate across massive distributed environments without performance degradation, the framework implements a decentralized **Semantic Partitioning** strategy.

### 10.1 Regional Region-Hash Indexing
The entire 384-dimensional vector space is partitioned into **256 Semantic Regions**. Each actor is assigned a `region_id` based on its high-dimensional embedding hash. This partitioning allows the network to perform "Targeted Broadcasts," where query signals are routed only to the regions most likely to contain relevant nodes. This reduces network congestion and ensures that query evaluation latency remains sub-linear relative to the growth of the actor population.

### 10.2 Lock-Free Drift Management
The system maintains a high-frequency, read-optimized index (The Drift Index) that stores actor embeddings in a lock-free structure. This allows actors to perform "Synaptic Search" for new neighbors without causing circular GenServer deadlocks. A background process (The Drift Manager) periodically verifies that actors are still oriented correctly within their semantic regions, performing "Node Migration" if an actor's semantic identity evolves significantly enough to warrant moving to a different region of the space.

---

## 11. Concurrency & High-Frequency Persistence Strategies

The framework is optimized for the high-concurrency environment of the BEAM virtual machine, utilizing advanced message-passing and storage strategies.

### 11.1 Sharded Hebbian Buffering
Synaptic weight updates (Hebbian reinforcement) are high-frequency events that could easily cause process bottlenecking. To mitigate this, the system utilizes a **Sharded Buffering** strategy. Updates are routed to regional buffers that aggregate modifications before performing batch writes to the persistence layer. This reduces disk I/O contention and prevents local actor processes from being blocked by synchronization tasks.

### 11.2 Broadway-Backed Telemetry Pipelines
Telemetry ingestion for the CREMS is handled through a high-performance pipeline backed by the Broadway framework. This allows the system to process thousands of "Grip Reality" events per second from the sentinels. The pipeline features built-in backpressure and message shedding, ensuring that the system's "Sensory Buffer" never causes an OOM (Out Of Memory) event during periods of extreme system-wide turbulence.

---

## 12. System Integrity & Security Boundaries

The ecosystem enforces strict operational boundaries to protect the integrity of the data directory and prevent split-brain scenarios.

### 12.1 The Instance Guard (Git-Lock Mechanism)
To prevent multiple instances of the modelling system from writing to the same persistence root simultaneously, an **Instance Guard** is implemented. It utilizes an OS-level PID-lock file (the "running.pid"). Before a bootloader sequence can proceed, it must acquire this lock. If a stale lock is found from a dead process, the guard performs a "Self-Healing Retrieval" to clean the environment and ensure a safe boot.

### 12.2 Identity Verification
The system utilizes a cryptographic "Identity Lock" to verify that the rehydrated Mnesia schema matches the current machine architecture. If a mismatch is detected (e.g., trying to boot data from an incompatible node), the system triggers an "Emergency Rehydration" from the immutable epoch logs, resurrecting the connectome from the source of truth rather than risk corrupted state.

---

## 13. Operational Overview & Deployment Protocols

While the underlying architecture serves as a high-fidelity cognitive substrate, the operational interface provides the necessary handles for deployment and interaction.

### 13.1 Core System Capabilities
- **Decentralized Actor-Model Networking**: Infinite horizontal scalability via isolated actor processes.
- **High-Resolution Telemetry Transmutation**: Real-time conversion of system metrics into normalized physical indicators.
- **Spreading Activation Discovery**: Native associative search via decentralized firing dynamics.
- **Phantom Engine Predictive Simulation**: Force-vector based "What-If" analysis for distributed systems.
- **Merkle-Linked Temporal Persistence**: Append-only journaling with reverse-diff state reconstruction.
- **Autonomous Swarm Dynamics**: Recursive wavefront discovery of static and dynamic environments.

### 13.2 Environmental Prerequisites
The ecosystem is optimized for high-concurrency environments and requires the following substrate:
- **Erlang/OTP 26.0+**: Essential for the decentralized actor model.
- **Elixir 1.15+**: The core development language.
- **Gemini 2.5 Flash Lite API Access**: Necessary for the high-dimensional semantic bridge.
- **Linux Operating System**: Required for native process introspection and telemetry sentinels.
- **Mnesia Persistence Strategy**: Included in the standard OTP distribution.

### 13.3 The Universal API Interface
The ecosystem exposes a high-performance REST and WebSocket API through a centralized interface layer, allowing external agents and services to interact with the cognitive substrate.

#### 13.3.1 Knowledge Ingestion API
- **POST `/api/v1/ingest/blob`**: Ingest raw data payloads directly into the substrate.
- **POST `/api/v1/ingest/upload`**: Multipart upload support for large-scale asset ingestion.
- **POST `/api/v1/ingest`**: Standard entry point for structured entity injection.

#### 13.3.2 Decentralized Query & Search
- **POST `/api/v1/query/unified`**: The primary search gate utilizing the Three-Gate Triage logic (Symbolic, Nominal, Semantic). Returns ranked results based on spreading activation.
- **POST `/api/v1/query`**: Direct interface for semantic vector search across the partitioned regional indices.

#### 13.3.3 Node & Temporal Management
- **GET `/api/v1/nodes/:id`**: Retreive the full quad-partite state of a specific actor.
- **GET `/api/v1/nodes/:id/history`**: Access the temporal reverse-diff stack for an entity.
- **GET `/api/v1/nodes/:id/edges`**: Inspect the functional and semantic connectivity of a node.
- **POST `/api/v1/nodes/:id/feedback`**: Provide anti-Hebbian penalization to refine the link topology.

#### 13.3.4 Real-time Signal Stream (WebSocket)
- **WS `/api/v1/events`**: A dedicated pub/sub gateway for real-time firing signals, mutation events, and physiological state updates. This allows external dashboards to visualize the subsystem's "Pulse" as it occurs.

### 13.4 Substrate Genesis & Environmental Binding
The framework supports two distinct Genesis protocols to establish the initial cognitive substrate.

#### 13.4.1 Static Genesis (CDMS Mapping)
To map a static filesystem environment, execute the hierarchical crawl sequence:
```bash
mix cdms.genesis --path /path/to/target --mode deep
```
This initializes the wavefront expansion agents and performs the initial phase ofconnectome forgery.

#### 13.4.2 Runtime Genesis (CREMS Modelling)
To initialize the dynamic reflection of the operating system and virtual machine, the **Runtime Swarm** must be triggered. This instantiates the "Mother Node" and spawns recursive modelling agents to map the process tree:
```elixir
# Trigger via the cognitive console or API
CREMS.Ingestion.RuntimeSwarm.start_genesis()
```

### 13.5 Automation & Startup Ecosystem
The project includes several automation scripts to streamline deployment and environment preparation.

#### 13.5.1 The CDMS Global CLI (`cdms.sh`)
A comprehensive bash-based launcher that simplifies the boot sequence. It automatically resolves the project root, manages environment variables via `.env` injection, and enforces data directory isolation within a hidden `.cdms_model` folder.
```bash
./cdms.sh --port 4000 --mode generative --name production_node
```

#### 13.5.2 Tooling & Diagnostics
- `install.sh`: Automated dependency verification and environment setup.
- `cdms_tool.sh`: A utility script for common maintenance tasks and substrate health checks.
- `test_api.sh`: A validation suite for verifying the availability and responsiveness of the Universal API layer.

### 13.6 Environmental Configuration & Setup

To secure and configure the cognitive substrate, you must establish the operational environment before boot. The system utilizes dynamic runtime resolution to ensure that no secrets are hardcoded in the source.

#### 13.6.1 Method 1: The .env File (Recommended)
The system automatically detects and loads a `.env` file in the project root if it exists. 
1. Copy the provided template: `cp .env.example .env`
2. Populate the `GEMINI_API_KEY` with your valid Google AI Platform credential.
3. The system will inject these variables into the BEAM environment at startup.

#### 13.6.2 Method 2: Direct Shell Export
For containerized or temporary deployments, you can export variables directly:
```bash
export GEMINI_API_KEY="AIzaSy..."
export LLM_PROVIDER="gemini"
./cdms.sh
```

#### 13.6.3 Key Variable Registry
- `GEMINI_API_KEY`: **Required**. Authentication for the high-dimensional vector bridge (Gemini 2.5 Flash Lite).
- `LLM_PROVIDER`: Defines the semantic engine backend (`gemini` or `ollama`). Defaults to `gemini`.
- `ACMS_PORT`: The listener port for the Universal API and WebSocket gateway. Defaults to `4000`.
- `ACMS_DATA_DIR`: The filesystem path where the Mnesia registry and vector indices are stored. Defaults to `memory_cartridges/default`.
- `ACMS_SECRET`: A 32-byte base64 string used for session security. If missing, a unique key is auto-generated per boot.
- `ACTIVATION_THRESHOLD`: The baseline resistance (0.0 to 1.0) for spreading activation firing. Defaults to `0.35`.
- `HEBBIAN_REINFORCEMENT_GAIN`: The strength multiplier for usage-based synaptic weight updates.
- `PHANTOM_RELIANCE_COEFFICIENT`: Internal physics multiplier for predictive simulations.
- `MAX_REGIONAL_CONCURRENCY`: Controls the number of concurrent task streams allowed during regional drift management.


### 13.5 Basic Operation & Querying
The primary interface for interacting with the substrate is the decentralized query coordinator. You can initiate a query broadcast via the console:

```elixir
# Initiate a decentralized semantic broadcast
CMS.Interface.Console.query("Identify the primary functional dependencies in the physics engine.")
```

### 13.6 Structural Organization
The ecosystem is organized into three distinct operational layers, ensuring clear separation of concerns:
- **The Infrastructure Layer**: Handles high-performance persistence (Mnesia, Epoch Logs), high-speed communication (PubSub, Broadcast), and semantic bridge interfaces (Gemini).
- **The Core Cognitive Layer**: Contains the foundational logic for the distributed substrate, including the actor schemas, the physics transmutation engines, and the connectivity forgery protocols.
- **The Services & Interface Layer**: Provides the high-level orchestration for environment discovery, query routing, and real-time monitoring of the model's integrity.

### 13.7 Security & Isolation Policies
To ensure the stability of the digital substrate, the system enforces several security boundaries:
- **Cryptographic Identity Validation**: All nodes are addressed using content hashes to prevent document-spoofing or identity collisions in the distributed network.
- **Environment Isolation**: The `Instance Guard` precludes the secondary boot of overlapping substrate instances, preventing catastrophic corruption of the underlying Mnesia registry.
- **Sanitized Semantic Ingestion**: The `Exclusion Cortex` prevents the ingestion of sensitive artifacts (e.g., `.env`, `.ssh`, `.git`) by default, ensuring that the AI agent's proprioception is limited to functional code and system telemetry.
- **Environment-Based Secret Management**: All API keys, tokens, and sensitive credentials are managed exclusively through environment variables. The system enforces a strict "No Hardcoded Secrets" policy, utilizing dynamic runtime resolution to fetch credentials only when needed.

### 13.8 Troubleshooting & Diagnostic Feedback
If the cognitive substrate exhibits instability or performance drift, utilize the following diagnostic pathways:
- **Substrate Fragmentation**: If query relevance scores decline significantly, run `mix cdms.compact` to re-align regional indices and purge stale synaptic traces.
- **Connectivity Staleness**: If the connectome fails to reflect physical filesystem changes, verify that the `LiveWire` sentinel is active and has the appropriate operating system permissions to monitor the `PROJECT_ROOT`.
- **Inhibition Overdrive**: If the system's firing gain appears overly dampened, inspect the global inhibition factor via the console. High inhibition is often a symptom of excessive systemic noise or resource exhaustion in the underlying VM.

---

## 14. Contributing & Development Standards
Participation in the evolution of the CDMS/CREMS ecosystem requires adherence to rigorous engineering standards:
- **Semantic Commit Protocols**: All modifications must be committed with descriptive markers indicating if they affect the Infrastructure, Core, or Interface layers.
- **Cognitive Integrity Testing**: New modules must be validated against the `FIDValidator` to ensure they do not introduce structural anomalies into the actor schema.
- **Asynchronous Pattern Enforcement**: Contributions must utilize non-blocking GenServer patterns to preserve the sub-millisecond responsiveness of the spreading activation network.

---

## 15. Conclusion: The Unified Digital Nervous System

By combining decentralized actor-model dynamics, high-resolution telemetry transmutation, and Merkle-linked temporal persistence, the CDMS/CREMS ecosystem provides a unified digital nervous system. It transfigures a fragmented software environment into a meaningful, navigable, and predictable **Cognitive Substrate**. This framework empowers autonomous AI agents with the proprioception and foresight necessary to manage the extreme complexity of modern distributed systems.

---