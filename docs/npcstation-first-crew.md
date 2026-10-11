# First NPC crew prototype

This branch implements the first body/action/local inference slice of NPCstation.
It is an opt-in development prototype, not a complete single-player game mode.
NPCs are ordinary humans with minds, job equipment, ID access, and manifest entries.
You still start a normal round and spawn the crew through an admin verb.

## Start with the deterministic bridge

Use the fork's normal setup/build instructions in [README.md](../README.md).
The pinned BYOND version is in [dependencies.sh](../dependencies.sh). On Windows,
`bin/build.cmd` builds the game and `bin/server.cmd` hosts it. Set up your local
admin account using the normal `config/admins.txt` instructions.

1. In `config/npcstation.txt`, uncomment `NPCSTATION_ENABLED`. Leave the bridge
   URL at `http://127.0.0.1:8088`. Restart the game server after editing config.
2. Open another terminal in the repository and run:

   ```bat
   bin\npcstation-bridge.cmd --mode fake
   ```

   Linux/macOS, or Windows with your own Python 3.11+:

   ```sh
   python tools/npcstation_bridge/bridge.py --mode fake
   ```

3. Check `http://127.0.0.1:8088/health` in your browser. This confirms the bridge
   process is listening; it does not benchmark a model or verify an Ollama install.
4. Join the local server, start the round, and use **Spawn NPC Crew** in the admin
   Fun category. Spawn one Assistant named **NPC 1** on an open floor beside you.
5. Put a wrench on the floor within seven tiles of the NPC. Walk a few tiles
   away, remain in sight, and say: **NPC 1, bring me that wrench**.

The NPC should walk to the wrench, pick it up, return to you, drop it on the
floor, and announce delivery. Say **NPC 1, follow me** to test following, then
**NPC 1, stop** to cancel immediately. The name followed by a comma or colon is
required; ordinary conversation does not replace the NPC's task.

Fake mode only recognizes fetch, follow, and stop commands. It exercises the
same HTTP protocol and real in-game actions as the model, without GPU inference.
Use **NPC Crew Status** in the admin Debug category to inspect the current action,
bridge errors, pending request, and instruction revision. The existing AI behavior
tree viewer can also display the NPC's execution leaf.

## Switch to your local model

Install/run Ollama on the same computer. Pull a model you want to test, for
example `ollama pull qwen3:8b`. This is a starting candidate for the 4080 Super,
not a measured hardware recommendation. Start with one NPC and measure latency
and memory usage before adding more. This implementation uses a shared model
with separate bounded context for each NPC, not a loaded model per crew member.

Stop the fake bridge and run:

```bat
bin\npcstation-bridge.cmd --mode ollama --model qwen3:8b
```

Or:

```sh
python tools/npcstation_bridge/bridge.py --mode ollama --model qwen3:8b
```

The default Ollama origin is `http://127.0.0.1:11434`; `--ollama-url` can select
another loopback port. The bridge uses native `/api/chat`, JSON schema output,
non-streaming responses, a bounded context, and a 15-second inference timeout.
The first model load may exceed the timeout: let Ollama warm up and the NPC will
retry. A missing model or failed inference produces an error, not simulated
success. There is no cloud API dependency or automatic model download.

## What the game permits

| Action | Current behavior |
| --- | --- |
| `move_to` | Path to a currently visible or remembered entity's last observed turf; stop within one tile. |
| `follow` | Follow a visible person for at most 60 seconds; the planner can renew it. Search their last seen position if sight is lost, then report the loss. |
| `pick_up` | Click a visible, reachable floor item with an empty hand; verify that it is actually held. |
| `drop` | Drop a held item through the normal inventory API; verify that it is on the NPC's turf. |
| `inspect` | Return the normal examination text of a visible object. |
| `say` | Attempt a short sentence in ordinary local speech. Speech impairments still apply. |
| `wait` | Wait 1–10 seconds without inference every game tick. |
| `stop` | Stop the current movement/action. An addressed stop command also works without the bridge. |

Pathfinding uses the NPC's real access. Walls, locked/bolted doors, restrained
movement, occupied hands, deleted items, and loss of sight can defeat a task.
Failed clicks are not reported as successful pickups. Items inside containers,
backpacks, lockers, or other people's inventories are outside this first slice.
Movement stays on one z-level and does not provide shuttle/elevator travel.

Perception is bounded to local visible mobs/items and held items, plus a small
last-seen memory. No camera, station-wide roster, hidden inventory, omniscient
medical diagnosis, or remote live position feed is sent to the model. Addressed
radio speech uses actual radio routing, but a radio sender's location is not
revealed. Deafness, unknown languages, and out-of-range whispers are rejected.
Sign language and NPC-to-NPC conversation are not supported yet. Darkness,
special senses, and every speech mutation still need more dedicated coverage.

Each NPC has at most one in-flight decision. The default global limit is two
requests, with round-robin scheduling. HTTP work is asynchronous in rust-g, so
a slow or offline model does not block the game tick. Timeout/error retries wait
10 seconds. NPCs with no directive do not request inference. Old decisions are discarded after a newer instruction, interruption,
or player takeover. A player taking the body cancels NPC control; control resumes
after logout, with the previous directive cleared.

NPCs can take damage, become incapacitated, and die. This slice stops actions
when they cannot act; it does not yet implement autonomous firefighting, treatment,
eating, breathing equipment selection, or a complete survival routine. Spawning
an Engineer or Miner gives the job's gear/access, not its operational skills.
Solar setup, SM startup/monitoring, mining, and cross-z logistics are the next
separate role procedures. They must use real machine operations and verified
postconditions rather than asking the model to narrate a successful setup.

## Checks

```sh
python -m unittest discover -s tools/npcstation_bridge -v
```

Bridge tests cover an HTTP fetch sequence, failed actions, lost targets, crew/round
isolation, malformed observations/model output, bounded inference concurrency,
and the Ollama request/response adapter using a local stub. They need no model.

Game unit tests in `code/modules/unit_tests/npcstation.dm` exercise real human
hands/items, reach/full-hand failures, clientless hearing, whisper/deafness
filters, stale decisions, takeover cancellation, and last-seen locations. Run
them through the repository's normal BYOND unit test workflow. Do not enable the
bridge in CI. Manual acceptance still includes access-controlled doors, a moved
or deleted wrench, model shutdown/restart, and playing a local shift on your GPU.

