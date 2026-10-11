# NPCstation: local AI crew implementation plan

Status: planning document; no NPC gameplay implementation is included in this change.

Repository: https://github.com/puemekaw/NPCstation
Inspected baseline: 1568dbe1daeba67dc20939c6307d07522967e89c
Inspection date: 2026-10-11
Target development machine: RTX 4080 Super (16 GB VRAM), 64 GB system RAM.

## 1. Intended game

Build a locally hosted SS13 mode in which one player can perform an ordinary station job, command the station, or eventually play an antagonist among independent NPC crew. Crew must work with actual bodies, injuries, hands, inventories, access cards, machines, speech, and environmental hazards.

The first complete playable target is a small station with eight station NPCs, one or two mining crew, and one player. Crew perform useful department work, start and maintain critical infrastructure, sustain the station's resource supply, exchange information, respond to incidents, and make mistakes that have understandable causes. Local language-model decisions are part of the early prototype.

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

### M3B — Critical infrastructure and mining

Critical station jobs are part of the first functional station target. Preconfigured power is a fixture for early body/model/medical tests; the playable mode must support NPC startup and ongoing operation.

A job skill has preconditions, real actions, observable completion criteria, interruption handling, and recovery paths. The model chooses priorities and interprets exceptions; tested procedures handle routine startup. Use these procedures for repeatable work while retaining general actions for inspection and supported deviations.

Start with one supported station layout. Define a map profile containing known work locations, operator-accessible controls, a verified startup recipe, and required tools/supplies. Resolve the actual installed machines at runtime and inspect their current state. Extend to other layouts through additional profiles and tests rather than assuming one universal SM configuration.

#### Engineering: solars

Procedure:
1. Obtain appropriate space equipment, internals, tools, and cable.
2. Reach the array, inspect panels/tracker, and complete or repair the required connections.
3. Refresh the control's discovered devices and enable appropriate tracking.
4. Configure the associated SMES charging/output through normal operator controls.
5. Verify panel connectivity, tracking, measured generation under sunlight, storage behavior, and supply to the intended network.
6. Continue inspections and create repair tasks when output deviates from the expected conditions.

The [solar controller](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/power/solar.dm) exposes connected panels, tracker presence, tracking state, supply, and capacity. Its refresh and automatic-tracking behavior provide concrete adapter points. [SMES](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/power/smes.dm) supplies the storage side. NPCs must carry equipment and perform the physical work; completion is defined by the operating installation.

Acceptance: from the selected map's normal round-start state, the engineer brings the array online without player assistance. A missing connection or tracker produces diagnosis, repair, or an accurate request for help. Zero generation during shadow is interpreted in context.

#### Engineering: supermatter startup, watch, and faults

Use a tested startup procedure for the selected engine layout:
1. Inspect the installed cooling/exhaust system, control settings, coolant supply, and power equipment.
2. Prepare and validate the coolant path before energizing the crystal.
3. Configure pumps, filters, storage, and associated devices using the profile's verified settings.
4. Enable emitters through their actual controls when the startup preconditions hold.
5. Verify useful power production and acceptable integrity/operating trends over a test-defined observation window.
6. Maintain an engine-watch task after startup and investigate alarms and deteriorating readings.

The [SM monitor program](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/modular_computers/file_system/programs/sm_monitor.dm) already uses [sm_ui_data](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/power/supermatter/supermatter.dm) and delamination-alarm signals. Provide the NPC the readings obtainable through its actual monitor/device access. Additional loop information comes from inspected controls and gas-analysis equipment.

Handle known faults first: disabled pump, missing coolant, broken connection, power loss, and supported contamination cases. A detected failure can interrupt startup, suppress further energization, prioritize corrective work, and request another engineer. Turning emitters off does not finish an SM emergency: maintaining/restoring cooling and verifying the subsequent trend remain tasks.

Hold a shared engine-operation reservation so two engineers do not issue conflicting adjustments. One can operate the engine while another performs a requested repair or maintains solars. If the system is beyond supported recovery, crew issue warnings and coordinate evacuation.

Acceptance: start the map's normal SM configuration through real controls, sustain it, and recover from selected injected faults. Report unsupported conditions accurately. Test startup with an absent dependency and interruption during a step; reconcile actual state before resuming.

#### Mining: sustained resource work outside the player's view

Provide an equipped shaft miner, a work mission, and an actual route between station and mining area:
1. Check suit/internals, tools, weapon, scanner, medical supplies, and navigation beacons.
2. Travel using the existing shuttle/elevator/transport mechanism for the selected map.
3. Explore from known terrain, scan deposits, and choose extraction targets based on station demand.
4. Extract resources using the fork's supported mechanics.
5. Maintain the required navigation, retrieval, and processing route.
6. Respond to fauna, storms, injury, equipment limits, and blocked routes; retreat or request help when appropriate.
7. Return or arrange material delivery, replenish equipment, and repeat the mission.

This baseline includes [ore vents](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/game/objects/structures/lavaland/vent_mining/ore_vent.dm), wave defense, [Candela navigation beacons](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/mining/equipment/candela_network/candela_beacons.dm), and [boulder processing](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/mining/boulder_processing/_boulder_processing.dm). Mining support must cover this current pipeline as applicable to the selected map; a generic rock-clicking loop is only an initial body/action exercise. Existing [Mook mining behaviors](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/modules/mob/living/basic/lavaland/mook/mook_bt.dm) provide patterns for deposits and storm retreat, not a complete human miner implementation.

Ore-vent excavation currently includes a player TGUI confirmation. Add a validated clientless operation adapter by sharing the underlying operation with the player path, preserving scanner, proximity, eligibility, cooldown, and completion checks. Apply the same approach to supported computer controls: reuse bounded operator actions and their effects while preserving ordinary physical/access checks.

The base controller can turn off off-station AI when no client is nearby. NPC mining crew need RUN_WHILE_UNWATCHED and appropriate priority handling in [the controller](https://github.com/puemekaw/NPCstation/blob/1568dbe1daeba67dc20939c6307d07522967e89c/code/datums/ai/_ai_controller.dm). Background work must continue when the player stays on station; combat and urgent danger need sufficiently responsive processing. Cross-z travel requires explicit transport steps, not just a pathfinding target on a different z-level.

Acceptance: a miner carries out a supported mining expedition while the player stays on station; real materials reach the station's usable supply pipeline. A second test introduces a storm/injury or breaks a beacon connection and verifies retreat/recovery. Model delay must not suspend immediate combat or hazard responses.

#### Other critical station services

Define service tasks with explicit readiness/completion checks:
- Medical: stocked working treatment capability, basic rescue, and a route to preparing or obtaining essential supplies.
- Atmospherics/maintenance: supported air alarms, hull breaches, fire response, damaged wiring, APC/SMES faults, and supplies required for repairs.
- Cargo: supply requests, credits/availability checks, receiving, and delivery to the requesting department.
- Food: maintain a usable supply and replenish ingredients.
- Command: assign unclaimed critical work, coordinate incident response, and invoke evacuation through supported controls.

Track requested materials and spare parts so miners and cargo receive concrete demand from engineering, medical, and other departments. Release task reservations on failure, death, or loss of the assigned worker. NPCs should run startup work without an explicit player order when their department's readiness conditions are unmet.

A complete playable milestone requires critical services and resource supply to function without the player personally starting each department. The initial eight station crew are a benchmark roster; add one or two miners and further specialists as the supported jobs and measured performance require.

### M4 — Coordination and individuality

- Expand to two to four NPCs.
- Add task reservations with expiry and release on failure/death.
- Add department radio requests and shared tasks with explicit handoff.
- Add memory, trust, risk tolerance, diligence, and social behavior.
- Ensure information travels through actual observations and communication.

Exit: two doctors do not endlessly compete over the same task, an NPC can ask another department for assistance, and two characters can react differently to the same situation while maintaining their own knowledge.

### M5 — Small playable station

Initial station roster: one captain, two engineers, one doctor, one security officer, one cargo technician, one cook, and one janitor. Add one or two shaft miners for resource work, then additional specialists as necessary.

After the shared body/model interface, prioritize medical and engineering startup, followed by mining/resource supply, janitorial work, cargo delivery, cooking, security, and command. Every role begins with a narrow, reliable set of responsibilities, including the critical infrastructure and mining checks in M3B.

Use an existing map for development; select or adapt a smaller station after the interaction loop is proven. Preconfigured power is available for early controlled tests. The complete playable milestone starts from the supported map's ordinary infrastructure state and requires NPCs to bring its supported solars/SM and resource pipeline into operation.

Add controlled incidents and eventual NPC antagonists. A traitor receives an explicit objective and acts through the same physical abilities and perception constraints. Security builds suspicion from evidence and reports.

Audit Dynamic and event population assumptions: their normal counts refer to players, not this NPC roster. Add an explicit NPCstation crew/event policy instead of pretending NPCs are connected clients or blindly inserting them into player lists.

Exit: play a complete shift with autonomous infrastructure startup, sustained material supply, useful crew, an incident, coordination, and evacuation. Outcomes should follow the simulation rather than requiring the player to fix every department personally.

### Later expansion

Advanced engineering/atmospherics, surgery, science, botany, complex antagonist plans, expanded social memory, and optional persistent campaign features follow the working station loop. Mid-round world saves and a global pause are separate engineering features requiring their own design.

## 6. Scheduling and hardware strategy

Load one model and keep isolated character contexts. Persist memories in the bridge and send bounded relevant context. Separate logical agents from inference-worker count.

Start with a small number of simultaneous requests. Prioritize direct player interaction and urgent task replanning, stagger idle decisions, merge redundant events, and cap retries and action loops. A reply rendered obsolete by a new event should not restart old work.

GPU memory must hold the model plus runtime/cache overhead; 64 GB system RAM is useful but does not add 64 GB of GPU memory. Prefer a model that fits comfortably on the GPU with the selected context and worker settings.

Measure at one, two, four, and eight NPCs, then with the added mining crew:
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
- Solar startup with a missing cable/tracker and generation changing with sunlight.
- SM startup, interrupted configuration, selected cooling/power faults, and conflicting engineer requests.
- A miner working off-station while unwatched, using actual transport, receiving hazard warnings, and maintaining material delivery.
- Supported machine/vent operations invoked by a clientless NPC with ordinary eligibility checks.

Bridge checks cover schema failures, unsupported commands, bounded context, request identity, timeouts, overload, and deterministic replay of action results. Live playtests assess whether the chosen model makes useful decisions; valid JSON alone does not establish NPC competence.

Use bin/test.cmd for DM tests on Windows; use the supported build targets on other platforms. Preserve the inherited CI and coding conventions. A new bridge should have its own lightweight fixture checks without requiring live inference in CI.

### First implementation changes

1. Human controller and body/action test harness, including clientless hearing and lifecycle.
2. Local bridge and asynchronous structured-action loop, with one assistant retrieval demo.
3. Doctor actions and one complete patient-treatment scenario.
4. Operator-control adapters and a checked solar startup procedure for one map.
5. A verified SM startup/watch procedure and a mining expedition with material delivery.

Each change should be independently reviewable and include its acceptance demonstration. Keep upstream merges deliberate during the prototype so integration failures remain attributable.

## 9. Inspection and validation limits

This plan is based on source inspection of the pinned fork commit and a local source checkout. Relevant existing paths and routines were read; the working tree was clean before this documentation change.

No BYOND compiler or local Ollama instance was available in this execution environment. The unchanged game has not been compiled here, the GPU has not been benchmarked, and the proposed bridge/actions have not been implemented.

The next concrete development target is M1/M2: one real human NPC that hears the player and uses local-model decisions to retrieve and deliver an item through normal SS13 interactions.
