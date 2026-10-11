/// A human body driven through the same movement and item APIs as the rest of the game's AI.
/datum/ai_controller/npcstation
	ai_movement = /datum/ai_movement/jps
	ai_traits = STOP_MOVING_WHEN_PULLED|RUN_WHILE_UNWATCHED
	movement_delay = 0.4 SECONDS
	behavior_nodes = list(/datum/bt_node/ai_behavior/npcstation_execute)
	/// Identifiers are scoped to this controller, never BYOND refs or executable type paths.
	var/agent_id
	var/revision = 0
	var/next_target_id = 0
	var/next_event_id = 0
	var/pending_decision_id
	var/next_decision_at = 0
	var/list/known_targets = list()
	var/list/recent_events = list()
	var/list/directive
	var/list/current_action
	var/list/last_result
	var/action_decision_id
	var/action_deadline = 0
	var/bridge_status = "idle"

/datum/ai_controller/npcstation/New(atom/new_pawn)
	SSnpcstation.next_agent_id++
	agent_id = "crew-[SSnpcstation.next_agent_id]"
	. = ..()
	if(!isnull(pawn))
		SSnpcstation.crew += src

/datum/ai_controller/npcstation/Destroy(force)
	SSnpcstation.crew -= src
	QDEL_LIST_ASSOC_VAL(known_targets)
	return ..()

/datum/ai_controller/npcstation/TryPossessPawn(atom/new_pawn)
	if(!ishuman(new_pawn))
		return AI_CONTROLLER_INCOMPATIBLE
	RegisterSignal(new_pawn, COMSIG_MOVABLE_PRE_HEAR, PROC_REF(on_hear))
	RegisterSignal(new_pawn, COMSIG_MOB_AI_MOVEMENT_FAILED, PROC_REF(on_movement_failed))
	RegisterSignal(new_pawn, COMSIG_MOB_MOVESPEED_UPDATED, PROC_REF(on_movespeed_changed))
	return ..()

/datum/ai_controller/npcstation/UnpossessPawn(destroy)
	SSnpcstation.crew -= src
	if(!isnull(pawn))
		interrupt("Control ended.")
		UnregisterSignal(pawn, list(COMSIG_MOVABLE_PRE_HEAR, COMSIG_MOB_AI_MOVEMENT_FAILED, COMSIG_MOB_MOVESPEED_UPDATED))
	return ..()

/datum/ai_controller/npcstation/setup_able_to_run()
	. = ..()
	RegisterSignal(pawn, COMSIG_MOB_INCAPACITATE_CHANGED, PROC_REF(update_able_to_run))

/datum/ai_controller/npcstation/clear_able_to_run()
	UnregisterSignal(pawn, COMSIG_MOB_INCAPACITATE_CHANGED)
	return ..()

/datum/ai_controller/npcstation/get_able_to_run()
	var/mob/living/carbon/human/human = pawn
	if(QDELETED(human) || human.stat != STABLE || human.incapacitated || GET_CLIENT(human))
		return AI_UNABLE_TO_RUN
	return ..()

/datum/ai_controller/npcstation/update_able_to_run()
	. = ..()
	if(!able_to_run && (current_action || pending_decision_id))
		interrupt("Unable to act.")

/datum/ai_controller/npcstation/on_sentience_gained()
	interrupt("Player took control.")
	directive = null
	return ..()

/datum/ai_controller/npcstation/on_sentience_lost()
	. = ..()
	update_able_to_run()
	next_decision_at = world.time

/datum/ai_controller/npcstation/proc/on_movespeed_changed(mob/living/source)
	SIGNAL_HANDLER
	movement_delay = max(0.2 SECONDS, source.cached_multiplicative_slowdown)

/datum/ai_controller/npcstation/proc/autonomy_available()
	return !QDELETED(pawn) && CONFIG_GET(flag/npcstation_enabled) && !forced_off && !(get_able_to_run() & AI_UNABLE_TO_RUN)

/datum/ai_controller/npcstation/proc/needs_decision()
	return autonomy_available() && !isnull(directive) && isnull(current_action) && isnull(pending_decision_id) && world.time >= next_decision_at

/// Cancellation invalidates both inference responses and asynchronous item clicks.
/datum/ai_controller/npcstation/proc/interrupt(reason)
	revision++
	if(current_action)
		complete_action(NPCSTATION_FAILURE, reason)
	else if(ai_movement.moving_controllers[src])
		ai_movement.stop_moving_towards(src)
	cancel_current_plan()
	next_decision_at = world.time

/datum/ai_controller/npcstation/proc/on_movement_failed()
	SIGNAL_HANDLER
	if(current_action && (current_action["type"] in list(NPCSTATION_ACT_MOVE, NPCSTATION_ACT_FOLLOW)))
		complete_action(NPCSTATION_FAILURE, "Path blocked, inaccessible, or movement interrupted.")

/// PRE_HEAR runs for clientless humans; the regular HEAR signal does not.
/// Keep the perception checks here rather than giving the bridge unrestricted station speech.
/datum/ai_controller/npcstation/proc/on_hear(datum/source, list/hearing_args)
	SIGNAL_HANDLER
	if(!autonomy_available())
		return
	var/mob/living/carbon/human/human = pawn
	var/atom/movable/speaker = hearing_args[HEARING_SPEAKER]
	var/atom/movable/actual_speaker = speaker?.GetSource() || speaker
	if(QDELETED(actual_speaker) || actual_speaker == pawn || HAS_AI_CONTROLLER_TYPE(actual_speaker, /datum/ai_controller/npcstation))
		return
	if(HAS_TRAIT(human, TRAIT_DEAF) || !human.has_language(hearing_args[HEARING_LANGUAGE]))
		return
	var/list/message_mods = hearing_args[HEARING_MESSAGE_MODE]
	if(message_mods[MODE_CUSTOM_SAY_ERASE_INPUT] || HAS_TRAIT(speaker, TRAIT_SIGN_LANG))
		return
	// Radio has already been routed by telecomms. Local whispers must be intelligible at our distance.
	if(!hearing_args[HEARING_RADIO_FREQ])
		var/turf/speaker_turf = get_turf(speaker)
		var/turf/pawn_turf = get_turf(pawn)
		if(isnull(speaker_turf) || isnull(pawn_turf) || speaker_turf.z != pawn_turf.z || get_dist(speaker, pawn) > hearing_args[HEARING_RANGE])
			return
	var/message = trim(copytext_char(strip_html(hearing_args[HEARING_RAW_MESSAGE]), 1, NPCSTATION_MAX_TEXT + 1))
	var/prefix = "[human.name],"
	if(findtext(message, prefix) != 1)
		prefix = "[human.name]:"
		if(findtext(message, prefix) != 1)
			return
	message = trim(copytext_char(message, length_char(prefix) + 1))
	if(!length(message))
		return
	var/datum/npcstation_target/speaker_target = remember_target(actual_speaker, target_visible(actual_speaker))
	if(isnull(speaker_target))
		return
	interrupt("New instruction.")
	next_event_id++
	directive = list("id" = next_event_id, "speaker_id" = speaker_target.id, "text" = message)
	recent_events += list(directive.Copy())
	if(length(recent_events) > NPCSTATION_MAX_EVENTS)
		recent_events.Cut(1, 2)
	// A stop command works even while the model is offline or busy.
	if(LOWER_TEXT(message) in list("stop", "cancel", "hold position"))
		directive = null
		next_decision_at = world.time + NPCSTATION_RETRY_DELAY

/datum/ai_controller/npcstation/proc/target_visible(atom/target)
	var/mob/living/carbon/human/human = pawn
	if(QDELETED(target) || QDELETED(human) || human.is_blind())
		return FALSE
	return target in view(7, human)

/// Retains a bounded last-seen position, not a live remote tracking capability.
/datum/ai_controller/npcstation/proc/remember_target(atom/target, observed = FALSE)
	if(QDELETED(target))
		return null
	for(var/target_id in known_targets)
		var/datum/npcstation_target/known = known_targets[target_id]
		if(known.target_ref.resolve() != target)
			continue
		if(observed)
			known.last_turf = get_turf(target)
			known.last_seen = world.time
			known.observed_name = copytext_char(strip_html(target.name), 1, 241)
		return known
	if(length(known_targets) >= NPCSTATION_MAX_TARGETS)
		return null
	next_target_id++
	var/datum/npcstation_target/known = new(target, "entity-[next_target_id]", observed)
	known_targets[known.id] = known
	return known

/datum/ai_controller/npcstation/proc/build_observation()
	var/mob/living/carbon/human/human = pawn
	var/list/entities = list()
	var/list/visible_ids = list()
	// Evict dead/old observations; there is no station-wide object enumeration.
	for(var/target_id in known_targets.Copy())
		var/datum/npcstation_target/known = known_targets[target_id]
		var/atom/target = known.target_ref.resolve()
		if(QDELETED(target) || world.time - known.last_seen > NPCSTATION_MEMORY_TIME)
			known_targets -= target_id
			qdel(known)
	if(directive && isnull(known_targets[directive["speaker_id"]]))
		directive = null
	if(!human.is_blind())
		var/visible_count = 0
		for(var/atom/movable/target in view(7, human))
			if(target == pawn || (!ismob(target) && !isitem(target)) || !isturf(target.loc))
				continue
			var/datum/npcstation_target/known = remember_target(target, TRUE)
			if(isnull(known))
				continue
			visible_ids += known.id
			visible_count++
			if(visible_count >= NPCSTATION_MAX_VISIBLE)
				break
	for(var/obj/item/held as anything in human.get_held_items())
		var/datum/npcstation_target/known = remember_target(held, TRUE)
		if(known)
			visible_ids |= known.id
	for(var/target_id in known_targets)
		var/datum/npcstation_target/known = known_targets[target_id]
		var/atom/target = known.target_ref.resolve()
		var/visible = (target_id in visible_ids)
		var/held = isitem(target) && human.is_holding(target)
		entities += list(list(
			"id" = target_id,
			"name" = known.observed_name,
			"kind" = known.kind,
			"visible" = visible,
			"held" = !!held,
			"pickable" = visible && isitem(target) && isturf(target.loc),
			"distance" = visible ? get_dist(pawn, target) : null,
			"position" = known.last_turf ? npcstation_position(known.last_turf) : null,
		))
	return list(
		"self" = list("name" = human.name, "job" = human.job, "position" = npcstation_position(get_turf(human)), "empty_hands" = length(human.get_empty_held_indexes())),
		"entities" = entities,
		"events" = recent_events.Copy(),
		"directive" = directive,
		"last_result" = last_result,
	)

/datum/ai_controller/npcstation/proc/receive_decision(datum/npcstation_request/pending)
	if(pending.decision_id != pending_decision_id)
		return
	pending_decision_id = null
	if(pending.revision != revision)
		return
	if(!autonomy_available())
		return
	var/datum/http_response/response = pending.http.into_response()
	if(response.errored || response.status_code != 200 || length(response.body) > 8192)
		bridge_failure("Bridge unavailable or returned an HTTP error.")
		qdel(response)
		return
	var/list/envelope
	try
		envelope = json_decode(response.body)
	catch
		bridge_failure("Bridge returned invalid JSON.")
	qdel(response)
	if(!islist(envelope))
		bridge_failure("Bridge returned an invalid envelope.")
		return
	if(envelope["protocol_version"] != NPCSTATION_PROTOCOL_VERSION || envelope["session_id"] != SSnpcstation.session_id || envelope["agent_id"] != agent_id || envelope["decision_id"] != pending.decision_id || envelope["revision"] != revision)
		bridge_failure("Bridge returned a mismatched decision.")
		return
	if(!accept_action(envelope["action"], pending.decision_id))
		bridge_failure("Bridge returned an invalid or unknown action.")

/datum/ai_controller/npcstation/proc/bridge_failure(reason)
	bridge_status = reason
	next_decision_at = world.time + NPCSTATION_RETRY_DELAY

/// Per-controller weak target references prevent raw refs, foreign targets, and invented objects.
/datum/npcstation_target
	var/id
	var/datum/weakref/target_ref
	var/observed_name
	var/kind
	var/turf/last_turf
	var/last_seen

/datum/npcstation_target/New(atom/target, id, observed)
	src.id = id
	target_ref = WEAKREF(target)
	observed_name = observed ? copytext_char(strip_html(target.name), 1, 241) : "Heard speaker"
	kind = ismob(target) ? "mob" : "item"
	last_seen = world.time
	if(observed)
		last_turf = get_turf(target)

/datum/npcstation_target/Destroy()
	target_ref = null
	last_turf = null
	return ..()

/proc/npcstation_position(turf/location)
	if(isnull(location))
		return null
	return list("x" = location.x, "y" = location.y, "z" = location.z)

