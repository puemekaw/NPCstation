/// Validate the entire action before it becomes an executable plan.
/datum/ai_controller/npcstation/proc/accept_action(list/action, decision_id)
	if(!islist(action) || length(action) != 4 || !autonomy_available() || current_action)
		return FALSE
	var/action_type = action["type"]
	var/target_id = action["target_id"]
	var/text = action["text"]
	var/seconds = action["seconds"]
	if(!istext(action_type) || !istext(target_id) || !istext(text) || !isnum(seconds) || length_char(text) > NPCSTATION_MAX_TEXT)
		return FALSE
	if(!(action_type in list(NPCSTATION_ACT_MOVE, NPCSTATION_ACT_FOLLOW, NPCSTATION_ACT_PICK_UP, NPCSTATION_ACT_DROP, NPCSTATION_ACT_SAY, NPCSTATION_ACT_INSPECT, NPCSTATION_ACT_WAIT, NPCSTATION_ACT_STOP)))
		return FALSE
	if(action_type in list(NPCSTATION_ACT_MOVE, NPCSTATION_ACT_FOLLOW, NPCSTATION_ACT_PICK_UP, NPCSTATION_ACT_DROP, NPCSTATION_ACT_INSPECT))
		var/datum/npcstation_target/known = known_targets[target_id]
		var/atom/target = known?.target_ref.resolve()
		if(isnull(known) || QDELETED(target))
			return FALSE
	else if(length(target_id))
		return FALSE
	if(action_type == NPCSTATION_ACT_SAY)
		if(!length(trim(text)))
			return FALSE
	else if(length(text))
		return FALSE
	if(action_type == NPCSTATION_ACT_WAIT)
		if(seconds < 1 || seconds > 10)
			return FALSE
	else if(seconds != 0)
		return FALSE
	current_action = action.Copy()
	action_decision_id = decision_id
	action_deadline = world.time + (action_type == NPCSTATION_ACT_FOLLOW ? NPCSTATION_FOLLOW_TIMEOUT : NPCSTATION_ACTION_TIMEOUT)
	if(action_type == NPCSTATION_ACT_WAIT)
		action_deadline = world.time + seconds SECONDS
	bridge_status = "executing [action_type]"
	return TRUE

/datum/ai_controller/npcstation/proc/complete_action(status, detail)
	if(!current_action)
		return
	last_result = list(
		"decision_id" = action_decision_id,
		"type" = current_action["type"],
		"target_id" = current_action["target_id"],
		"status" = status,
		"detail" = copytext_char(detail, 1, 1025),
	)
	current_action = null
	action_decision_id = null
	bridge_status = status
	next_decision_at = world.time + 0.5 SECONDS
	if(ai_movement.moving_controllers[src])
		ai_movement.stop_moving_towards(src)

/// A normal behavior leaf makes actions visible in the existing AI tree debugger.
/datum/bt_node/ai_behavior/npcstation_execute
	label = "Execute NPCstation action"
	time_between_perform = 0.25 SECONDS

/datum/bt_node/ai_behavior/npcstation_execute/perform(seconds_per_tick, datum/ai_controller/npcstation/controller)
	var/async_flags = handle_async()
	if(async_flags)
		return async_flags
	if(!controller.current_action)
		return AI_BEHAVIOR_FAILED
	if(!controller.autonomy_available())
		controller.complete_action(NPCSTATION_FAILURE, "Unable to act.")
		return AI_BEHAVIOR_FAILED
	var/action_type = controller.current_action["type"]
	if(action_type == NPCSTATION_ACT_WAIT)
		if(world.time < controller.action_deadline)
			return AI_BEHAVIOR_DELAY
		controller.complete_action(NPCSTATION_SUCCESS, "Waited.")
		return AI_BEHAVIOR_SUCCEEDED
	if(world.time > controller.action_deadline)
		controller.complete_action(NPCSTATION_FAILURE, "Action timed out.")
		return AI_BEHAVIOR_FAILED
	if(action_type == NPCSTATION_ACT_STOP)
		controller.complete_action(NPCSTATION_SUCCESS, "Stopped.")
		return AI_BEHAVIOR_SUCCEEDED
	if(action_type in list(NPCSTATION_ACT_MOVE, NPCSTATION_ACT_FOLLOW))
		return controller.perform_movement()
	var/mob/living/carbon/human/human = controller.pawn
	if(world.time <= human.next_click || world.time < human.next_move)
		return AI_BEHAVIOR_DELAY
	return start_async()

/// Item clicks and examine/say can enter sleeping game procs, so execute them outside SSai_controllers.
/datum/bt_node/ai_behavior/npcstation_execute/perform_async(datum/ai_controller/npcstation/controller)
	var/list/action = controller.current_action
	var/action_revision = controller.revision
	var/list/result = controller.perform_interaction(action, action_revision)
	if(!async_still_valid() || QDELETED(controller) || controller.revision != action_revision || controller.current_action != action)
		return
	controller.complete_action(result["status"], result["detail"])
	finish_async(result["status"] == NPCSTATION_SUCCESS ? AI_BEHAVIOR_SUCCEEDED : AI_BEHAVIOR_FAILED)

/datum/ai_controller/npcstation/proc/perform_movement()
	var/datum/npcstation_target/known = known_targets[current_action["target_id"]]
	var/atom/target = known?.target_ref.resolve()
	if(QDELETED(target) || isnull(known.last_turf))
		complete_action(NPCSTATION_FAILURE, "Target has no known location.")
		return AI_BEHAVIOR_FAILED
	var/visible = target_visible(target)
	if(visible)
		known.last_turf = get_turf(target)
		known.last_seen = world.time
	var/turf/destination = known.last_turf
	var/turf/pawn_turf = get_turf(pawn)
	if(isnull(pawn_turf) || pawn_turf.z != destination.z)
		complete_action(NPCSTATION_FAILURE, "Cross-deck travel is not supported yet.")
		return AI_BEHAVIOR_FAILED
	var/following = current_action["type"] == NPCSTATION_ACT_FOLLOW
	if(following && !ismob(target))
		complete_action(NPCSTATION_FAILURE, "Can only follow a person.")
		return AI_BEHAVIOR_FAILED
	if(get_dist(pawn, destination) <= 1)
		if(ai_movement.moving_controllers[src])
			ai_movement.stop_moving_towards(src)
		if(following && visible)
			return AI_BEHAVIOR_DELAY
		complete_action(visible ? NPCSTATION_SUCCESS : NPCSTATION_FAILURE, visible ? "Reached target." : "Reached last seen location; target is no longer visible.")
		return visible ? AI_BEHAVIOR_SUCCEEDED : AI_BEHAVIOR_FAILED
	// Path to a last observed turf, rather than following a live ref through walls.
	ai_movement.start_moving_towards(src, destination, 1)
	return AI_BEHAVIOR_DELAY

/// Uses real hands, reach checks and clicks. Success always means a verified game postcondition.
/datum/ai_controller/npcstation/proc/perform_interaction(list/action, action_revision)
	var/list/failure = list("status" = NPCSTATION_FAILURE, "detail" = "Unable to interact.")
	if(!autonomy_available() || action_revision != revision || current_action != action)
		return failure
	var/mob/living/carbon/human/human = pawn
	if(action["type"] == NPCSTATION_ACT_SAY)
		// Escape say prefixes/emotes so a model cannot invoke admin/radio say modes.
		var/message = trim(strip_html(action["text"]))
		if(copytext_char(message, 1, 2) in list(";", ":", ".", "*"))
			failure["detail"] = "Speech must be ordinary local speech."
			return failure
		human.say(message)
		return list("status" = NPCSTATION_SUCCESS, "detail" = "Attempted local speech.")
	var/datum/npcstation_target/known = known_targets[action["target_id"]]
	var/atom/target = known?.target_ref.resolve()
	if(QDELETED(target))
		failure["detail"] = "Target no longer exists."
		return failure
	if(action["type"] == NPCSTATION_ACT_DROP)
		if(!isitem(target) || !human.is_holding(target))
			failure["detail"] = "Item is not in a hand."
			return failure
		var/obj/item/item = target
		if(!human.dropItemToGround(item) || QDELETED(item) || item.loc != get_turf(human) || human.is_holding(item))
			failure["detail"] = "Item could not be dropped."
			return failure
		return list("status" = NPCSTATION_SUCCESS, "detail" = "Dropped [known.observed_name].")
	if(!target_visible(target))
		failure["detail"] = "Target is not currently visible."
		return failure
	if(action["type"] == NPCSTATION_ACT_INSPECT)
		var/list/examination = target.examine(human)
		return list("status" = NPCSTATION_SUCCESS, "detail" = strip_html(jointext(examination, " ")))
	if(action["type"] != NPCSTATION_ACT_PICK_UP || !isitem(target) || !isturf(target.loc))
		failure["detail"] = "Only exposed floor items can be picked up."
		return failure
	if(get_dist(human, target) > 1 || !target.IsReachableBy(human))
		failure["detail"] = "Item is out of reach."
		return failure
	var/list/empty_hands = human.get_empty_held_indexes()
	if(!length(empty_hands) || !human.swap_hand(empty_hands[1], silent = TRUE))
		failure["detail"] = "No empty hand."
		return failure
	ai_interact(target, combat_mode = FALSE)
	if(QDELETED(human) || QDELETED(target) || action_revision != revision || current_action != action)
		return failure
	if(!human.is_holding(target))
		failure["detail"] = "Click did not pick up the item."
		return failure
	return list("status" = NPCSTATION_SUCCESS, "detail" = "Picked up [known.observed_name].")

