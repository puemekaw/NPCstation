/// Schedules local inference and polls rust-g HTTP jobs. Never waits for a model on the game thread.
SUBSYSTEM_DEF(npcstation)
	name = "NPCstation Bridge"
	wait = 0.5 SECONDS
	priority = FIRE_PRIORITY_NPC
	runlevels = RUNLEVEL_GAME | RUNLEVEL_POSTGAME
	var/list/crew = list()
	var/list/pending_requests = list()
	var/next_agent_id = 0
	var/next_decision_id = 0
	var/session_id

/datum/controller/subsystem/npcstation/Initialize()
	session_id = "[world.realtime]-[world.port]"
	return SS_INIT_SUCCESS

/datum/controller/subsystem/npcstation/stat_entry(msg)
	msg = "Crew:[length(crew)]|Pending:[length(pending_requests)]"
	return ..()

/datum/controller/subsystem/npcstation/fire(resumed)
	// Drain jobs even when the feature is switched off or the pawn is gone.
	for(var/datum/npcstation_request/pending as anything in pending_requests.Copy())
		if(!pending.http.is_complete())
			continue
		pending_requests -= pending
		var/datum/ai_controller/npcstation/controller = pending.controller_ref.resolve()
		if(!QDELETED(controller))
			controller.receive_decision(pending)
		qdel(pending)

	if(!CONFIG_GET(flag/npcstation_enabled))
		return
	for(var/datum/ai_controller/npcstation/controller as anything in crew.Copy())
		if(length(pending_requests) >= CONFIG_GET(number/npcstation_max_requests))
			break
		if(!controller.needs_decision())
			continue
		next_decision_id++
		var/decision_id = "decision-[next_decision_id]"
		var/list/payload = list(
			"protocol_version" = NPCSTATION_PROTOCOL_VERSION,
			"session_id" = session_id,
			"agent_id" = controller.agent_id,
			"decision_id" = decision_id,
			"revision" = controller.revision,
			"observation" = controller.build_observation(),
		)
		var/datum/npcstation_request/pending = new(controller, decision_id)
		pending.http.prepare(
			RUSTG_HTTP_METHOD_POST,
			"[CONFIG_GET(string/npcstation_bridge_url)]/v1/decision",
			json_encode(payload),
			list("Content-Type" = "application/json"),
			timeout_seconds = CONFIG_GET(number/npcstation_request_timeout),
		)
		controller.pending_decision_id = decision_id
		pending_requests += pending
		pending.http.begin_async()
		// Round robin: busy NPCs do not monopolize the inference slots.
		crew -= controller
		crew += controller

/// Owns an in-flight HTTP job independently of the pawn's lifetime.
/datum/npcstation_request
	var/datum/weakref/controller_ref
	var/datum/http_request/http
	var/decision_id
	var/revision

/datum/npcstation_request/New(datum/ai_controller/npcstation/controller, decision_id)
	controller_ref = WEAKREF(controller)
	http = new
	src.decision_id = decision_id
	revision = controller.revision

/datum/npcstation_request/Destroy()
	controller_ref = null
	QDEL_NULL(http)
	return ..()

