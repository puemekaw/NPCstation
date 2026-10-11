# NPCstation: local AI crew implementation plan

Status: planning document; no NPC gameplay implementation is included in this change.

Repository: https://github.com/puemekaw/NPCstation
Inspected baseline: 1568dbe1daeba67dc20939c6307d07522967e89c
Inspection date: 2026-10-11
Target development machine: RTX 4080 Super (16 GB VRAM), 64 GB system RAM.

## 1. Intended game

Build a locally hosted SS13 mode in which one player can perform an ordinary station job, command the station, or eventually play an antagonist among independent NPC crew. Crew must work with actual bodies, injuries, hands, inventories, access cards, machines, speech, and environmental hazards.

The first complete playable target is a small station with eight NPCs and one player. Crew perform useful department work, exchange information, respond to incidents, and make mistakes that have understandable causes. Local language-model decisions are part of the early prototype.

Eight NPCs is a development and benchmarking target, not a verified performance limit. Model choice and crew size will follow measurements on the target machine.

## 2. What the source already provides

These are confirmed source findings at the inspected commit.

| Existing code | Reuse in NPCstation | Important limitation |
| --- | --- | --- |
| [AI controller](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/datums/ai/_ai_controller.dm) | Possession, per-character blackboard, interaction routing, lifecycle, and player takeover handling | The base controller supplies infrastructure, not human job competence. |
| [AI ticker](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/controllers/subsystem/ai_controllers.dm) | Tick behavior trees and react to state changes | SelectBehaviors is marked SHOULD_NOT_SLEEP. Inference must not block this path. |
| [JPS movement](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/datums/ai/movement/ai_movement_jps.dm) | Navigate using the character's actual access | Test locked doors, unreachable destinations, moving targets, and route hazards. |
| [Monkey controller and behaviors](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/datums/ai/monkey/monkey_controller.dm) | Examples of clientless humanoid control and lifecycle signals | Create a separate crew controller. Monkey aggression and idle behavior are unsuitable defaults. |
| [Monkey Business test](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/unit_tests/monkey_business.dm) | Evidence that the controller can control carbon/human bodies | This is a smoke test, not an implementation of station jobs. |
| [Debug crew spawning](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/admin/admin_verbs.dm) | Existing example of assigning jobs, transferring minds, equipping humans, and registering the manifest | It spawns a debug roster at an observer location; NPCstation needs a bounded roster and appropriate spawn locations. |
| [Job equipment](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/controllers/subsystem/job.dm) and [job definitions](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/jobs/job_types/_job.dm) | Job outfits, ID access, equipment, skills, and job signals | get_spawn_mob and apply_prefs_job expect a player client. They are not a drop-in NPC factory. |
| [HTTP wrapper](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/datums/http.dm) | Nonblocking POSTs to the local planner service through rust-g | Poll completion, set a timeout, handle transport failure, and release references. |
| [Living speech](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/mob/living/living_say.dm) | Local/radio delivery, languages, hearing constraints, and virtual speakers | Hear returns early without GET_CLIENT. COMSIG_MOVABLE_HEAR alone will miss clientless crew. |
| [Behavior-tree viewer](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/datums/ai/bt_viewer.dm) | Inspect the controller's active behavior while debugging | Add concise decision/action diagnostics alongside it. |
| [Health analyzer](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/game/objects/items/devices/scanners/health_analyzer.dm) and [medical stacks](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/game/objects/items/stacks/medical.dm) | Actual scanner reports and actual treatment interactions | Treatment is an ongoing operation. A dispatched click is not proof that healing finished. |

The inspected tree contains no AGENTS.md. Relevant inherited guidance is in .github/CONTRIBUTING.md, .github/guides/STANDARDS.md, code/datums/ai/learn_ai.md, and code/modules/unit_tests/README.md.

Some prose build guidance predates the current build scripts. dependencies.sh is the version authority: BYOND 516.1685, rust-g 7.0.0, Bun 1.3.5, and Python 3.11.0 for repository tools. Use the repository build scripts.

## 3. Architecture

Keep physical simulation and action execution in DM. Use a local Python service for model requests, context assembly, queueing, structured-response validation, and inference diagnostics. Run one local model through Ollama, with separate character records and histories.

A dedicated /datum/ai_controller/npcstation controls normal /mob/living/carbon/human bodies. A small SSnpcstation subsystem schedules decision requests and polls asynchronous HTTP responses. Existing SSai_controllers and SSai_movement continue executing behavior and movement.

Enable NPCstation through an opt-in configuration flag, defaulting off, with the local bridge endpoint and roster settings specified separately. This keeps ordinary rounds and existing controllers available for comparison during development.

~~~mermaid
flowchart TD
    S["Character observations and events"] --> Q["Decision queue"]
    Q --> B["Local Python bridge"]
    B --> L["Shared local model"]
    L --> V["Validate proposed action"]
    V -->|Accepted| A["SS13 action executor"]
    V -->|Rejected| R["Action result"]
    A --> R
    R --> S
    H["Urgent hazard"] --> F["Immediate game behavior"]
    F --> S
~~~

### Decision cycle

1. Gather a bounded snapshot of this character's observations, inventory, relevant memories, and current action.
2. Queue a decision on a meaningful event, a failed/completed action, or an idle deadline.
3. Submit the request through /datum/http_request.begin_async.
4. The Python bridge sends a role-specific prompt and a constrained action schema to the shared model.
5. Validate the returned action in Python and again against the live game state in DM.
6. Execute a supported action through normal game interactions and movement.
7. Report observed completion, failure, interruption, or timeout; the next decision incorporates that result.

During inference the character can continue an existing task or safe fallback behavior. Immediate reactions to fire, suffocation, incapacitation, and attack must work while the model is busy or unavailable.

### Separate character state

Each NPC has a stable agent ID, name, job, personality, role knowledge, bounded recent events, remembered facts with timestamps and provenance, current task, and action history. Shared model weights do not mean shared knowledge.

An engineer may know station geography and their job procedures. A security officer learns about a crime through observation, a report, or an investigation. An NPC receives no automatic antagonist identity, hidden inventory, or unobserved machine status.

Facts learned by radio should remain distinguishable from direct observations. Store important facts in structured memory and summarize older dialogue so prompts do not grow throughout the round.

### Local service boundary

Initial endpoints:
- GET /health: service and model availability.
- POST /v1/decision: one character snapshot in, one typed action proposal out.

The POST can take time to return because the game HTTP request is asynchronous. Begin with a bounded service queue and one or two inference workers. Do not build a separate distributed agent platform for this prototype.

Include protocol version, round/session ID, agent ID, decision ID, and an agent generation counter in requests and responses. Validate proposed actions against current state when a reply arrives. Reject replies invalidated by death, deletion, player takeover, round replacement, or a cancelled task. Retain handles to outstanding HTTP requests until completion or expiry so late results can be discarded and cleaned up.

## 4. Action and observation interface

Start with a small reusable set of physically meaningful actions. Expand the list after the first character can reliably operate its body.

| Initial action | Intended behavior |
| --- | --- |
| say | Speak through ordinary character speech with bounded message length and rate. |
| inspect | Return normal, relevant examination information for a known target. |
| move_to | Navigate to an observed target or a remembered location. |
| follow | Follow a known person; use their last observed location when contact is lost. |
| pick_up | Pick up a reachable item into an available hand. |
| drop | Put a held item on the ground. |
| equip / select_hand | Manage supported equipment slots and the active hand. |
| use_held_item_on | Use the held item through normal interaction checks. |
| use_in_hand | Activate a supported held item. |
| wait / stop | Pause a task, stop moving, or wait for an operation to finish. |

Later, add tested job skills such as scan_patient, apply_medical_supplies, deliver_item, clean_mess, and repair_supported_fault. These skills can encapsulate routine action sequences while the model chooses priorities and combines skills with general actions.

Return one action at a time in the first version. A task can remain active across multiple game ticks; it does not require another inference request for every footstep or tick of treatment.

### Example response

The exact field names are a proposed contract, not existing APIs.

~~~json
{
  "protocol_version": 1,
  "round_id": "local-round-1",
  "agent_id": "crew-01",
  "decision_id": "crew-01-0007",
  "generation": 3,
  "action": {
    "type": "move_to",
    "target_id": "seen-04"
  }
}
~~~

The bridge returns a command proposal. DM owns the target registry and final execution authority. Target IDs resolve through an NPC-scoped registry of weak references to observed or legitimately known objects. Validate range, access, held items, incapacity, target existence, and supported interaction before execution. Use timestamps and remembered positions so a reference to a person does not supply continuous tracking through walls.

### Action results

Use explicit states: queued, running, succeeded, failed, interrupted, cancelled, and timed_out. Include a concise failure code such as access_denied, hands_full, target_lost, no_supply, or path_unreachable.

The base ai_interact returns TRUE after calling ClickOn; it does not return a reliable task-completion result. Build outcome adapters around postconditions and existing completion signals. For example, pickup succeeds when the expected item is actually held; treatment succeeds after its operation completes and the expected change or normal treatment result is observed.

### Hearing and medical observation

- Receive already-routed local/radio speech using the pre-hearing hook or a carefully scoped NPC hearing adapter. COMSIG_MOVABLE_PRE_HEAR occurs before the client guard.
- Apply actual deafness, unconsciousness, language, whisper/range, and radio restrictions before adding text to memory. A raw pre-hearing event is not automatically understandable speech.
- Resolve a virtual radio speaker to the actual speaker where appropriate. Deduplicate repeated delivery, ignore the NPC's own speech as a fresh prompt, and bound replies to prevent radio conversation loops.
- Support normal sight and examination; reveal detailed injuries after a legitimate examination or scanner interaction.
- Reuse real health-analyzer results, including scanner capability/readability checks. Avoid inventing a second, inconsistent medical diagnosis system.

## 5. Development milestones

### M0 — Reproducible baseline and model experiment

- Use the inspected commit as the initial upstream baseline and keep implementation in small feature branches.
- Compile and join an unchanged full checkout locally using bin/build.cmd and bin/server.cmd on Windows.
- Confirm a local model can produce the chosen action schema from representative NPC snapshots.
- Benchmark a quantized model around 8B parameters first; compare a larger candidate if quality needs it.
- Record model tag/quantization, context size, generation settings, latency, and task-choice quality.

Exit: an unchanged round runs, and the model returns valid useful action proposals. A live NPC integration is not claimed at this stage.

### M1 — A real human NPC body

- Add the separate crew controller, lifecycle handling, bounded roster factory, and an admin spawn command.
- Reuse the clientless debug-crew recipe for mind/job/equipment/manifest setup, while providing real names and correct locations.
- Verify job-slot accounting and clean deletion. Exclude temporary factory state from player-ready lists.
- Implement deterministic movement, follow, pickup, drop, stop, and ordinary speech.
- Provide a correctly filtered hearing event path for clientless humans.
- Run the NPC in a controlled test room and then on a real station.

Exit demo: a named NPC with normal job gear can hear a request, follow the player through an accessible door, pick up a nearby item, drop it, and stop acting when the player takes control of its body.

### M2 — Local model chooses real actions

- Add the Python bridge and asynchronous decision queue.
- Send character-specific snapshots and supported action definitions.
- Execute validated structured decisions using M1 actions.
- Return action results and let the model recover from failures.
- Add timeouts, stale-response rejection, fallback behavior, and decision/action diagnostics.

Exit demo: tell the NPC to retrieve a visible wrench. It locates the item, walks to it, takes it, returns to the player, and drops it nearby. If the door locks or its hands are full, it changes its plan or requests help. Turning off Ollama leaves the game responsive.

### M3 — First useful department: medical

- Spawn a doctor with an appropriate ID, headset, scanner, and actual medical supplies.
- Add a limited medical routine for straightforward brute/burn injuries and selected bleeding cases.
- Use actual scan reports to choose supported treatment.
- Support reaching a patient, using supplies, restocking from a known container, and requesting help.
- Test interrupted treatment, absent supplies, a moving patient, and an unsafe route.

Exit demo: the doctor responds to a medical request, reaches and scans the patient, performs suitable basic treatment, and accurately reports either the outcome or an obstacle. Advanced surgery and general critical-care competence are later capabilities.

### M4 — Coordination and individuality

- Expand to two to four NPCs.
- Add task reservations with expiry and release on failure/death.
- Add department radio requests and shared tasks with explicit handoff.
- Add memory, trust, risk tolerance, diligence, and social behavior.
- Ensure information travels through actual observations and communication.

Exit: two doctors do not endlessly compete over the same task, an NPC can ask another department for assistance, and two characters can react differently to the same situation while maintaining their own knowledge.

### M5 — Small playable station

Initial roster: one captain, two engineers, one doctor, one security officer, one cargo technician, one cook, and one janitor.

Roll out useful job skills in this order: medical, janitorial work, basic maintenance, cargo delivery, limited cooking, security, and command. Every role begins with a narrow, reliable set of responsibilities.

Use an existing map for development; select or adapt a smaller station after the interaction loop is proven. Begin with a predefined working power configuration and supported maintenance faults. Crew startup routines can take on more infrastructure later.

Add controlled incidents and eventual NPC antagonists. A traitor receives an explicit objective and acts through the same physical abilities and perception constraints. Security builds suspicion from evidence and reports.

Audit Dynamic and event population assumptions: their normal counts refer to players, not this NPC roster. Add an explicit NPCstation crew/event policy instead of pretending NPCs are connected clients or blindly inserting them into player lists.

Exit: play a complete shift with useful crew, an incident, coordination, and evacuation. Outcomes should follow the simulation rather than requiring the player to fix every department personally.

### Later expansion

Advanced engineering/atmospherics, surgery, science, botany, complex antagonist plans, expanded social memory, and optional persistent campaign features follow the working station loop. Mid-round world saves and a global pause are separate engineering features requiring their own design.

## 6. Scheduling and hardware strategy

Load one model and keep isolated character contexts. Persist memories in the bridge and send bounded relevant context. Separate logical agents from inference-worker count.

Start with a small number of simultaneous requests. Prioritize direct player interaction and urgent task replanning, stagger idle decisions, merge redundant events, and cap retries and action loops. A reply rendered obsolete by a new event should not restart old work.

GPU memory must hold the model plus runtime/cache overhead; 64 GB system RAM is useful but does not add 64 GB of GPU memory. Prefer a model that fits comfortably on the GPU with the selected context and worker settings.

Measure at one, two, four, and eight NPCs:
- Queue wait, inference time, and end-to-end decision latency, including p50 and p95.
- Invalid, stale, and timed-out responses.
- Actual task completion and recovery from failures.
- Repeated-action loops and excessive speech.
- AI/controller tick cost and overall simulation tick gaps relative to the baseline.
- Runtime memory and GPU utilization.

Choose crew size and model from these measurements. Eight NPCs can share one model while continuing movement and established tasks between decisions.

## 7. Proposed implementation locations

These paths are proposed additions, not files that already exist.

| Proposed path | Responsibility |
| --- | --- |
| code/datums/ai/npcstation/ | Crew controller, behavior tree, typed execution nodes, and blackboard keys where appropriate. |
| code/modules/npcstation/ | Agent records, scoped perception, job/roster factory, outcome adapters, and department skills. |
| code/controllers/subsystem/npcstation.dm | Decision request scheduling, polling, cancellation, and diagnostics. |
| code/controllers/configuration/entries/npcstation.dm | Feature flags, bridge endpoint, roster size, and scheduling limits. |
| tools/npcstation_bridge/ | Isolated Python service, model adapter, schemas, queue, memory, and fixture tests. |
| code/modules/unit_tests/npcstation_*.dm | Real-world DM tests for behavior, lifecycle, perception, and outcomes. |
| docs/npcstation/ | Protocol, local setup, model benchmark results, and playtest instructions. |

Register DM files through the existing include conventions. Add unit tests to code/modules/unit_tests/_unit_tests.dm and compile new behavior-tree JSON through the existing tools/build_bt.py build target.

## 8. Validation and first implementation backlog

Automated checks must run with a deterministic fake planner and no GPU, network service, or model download. Reserve real Ollama tests for explicit local playtests and benchmarks.

Meaningful DM scenarios:
- Open versus inaccessible doors, target movement/deletion, and failed pathfinding.
- Pickup with free/full hands and unreachable items.
- Speech delivery, language/deafness/whispers, radio routing, and self-echo suppression.
- Character death, deletion, player takeover, disconnect, and round cleanup.
- A late response attempting an obsolete or invalid action.
- Actual medical scan/treatment outcomes and interrupted operations.
- Two crew claiming one task; correct release and recovery.

Bridge checks cover schema failures, unsupported commands, bounded context, request identity, timeouts, overload, and deterministic replay of action results. Live playtests assess whether the chosen model makes useful decisions; valid JSON alone does not establish NPC competence.

Use bin/test.cmd for DM tests on Windows; use the supported build targets on other platforms. Preserve the inherited CI and coding conventions. A new bridge should have its own lightweight fixture checks without requiring live inference in CI.

### First three implementation changes

1. Human controller and body/action test harness, including clientless hearing and lifecycle.
2. Local bridge and asynchronous structured-action loop, with one assistant retrieval demo.
3. Doctor actions and one complete patient-treatment scenario.

Each change should be independently reviewable and include its acceptance demonstration. Keep upstream merges deliberate during the prototype so integration failures remain attributable.

## 9. Inspection and validation limits

This plan is based on source inspection of the pinned fork commit and a local source checkout. Relevant existing paths and routines were read; the working tree was clean before this documentation change.

No BYOND compiler or local Ollama instance was available in this execution environment. The unchanged game has not been compiled here, the GPU has not been benchmarked, and the proposed bridge/actions have not been implemented.

The next concrete development target is M1/M2: one real human NPC that hears the player and uses local-model decisions to retrieve and deliver an item through normal SS13 interactions.
