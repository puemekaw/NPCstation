/// These tests run without the bridge, Ollama, or a client. Real game objects exercise the executor.
/datum/unit_test/npcstation
	abstract_type = /datum/unit_test/npcstation
	var/previous_enabled

/datum/unit_test/npcstation/New()
	. = ..()
	previous_enabled = CONFIG_GET(flag/npcstation_enabled)
	CONFIG_SET(flag/npcstation_enabled, TRUE)

/datum/unit_test/npcstation/Destroy()
	. = ..()
	CONFIG_SET(flag/npcstation_enabled, previous_enabled)

/datum/unit_test/npcstation/proc/create_controller(mob/living/carbon/human/human)
	var/datum/ai_controller/npcstation/controller = allocate(/datum/ai_controller/npcstation, human)
	controller.next_decision_at = INFINITY // No external HTTP during CI.
	return controller

/datum/unit_test/npcstation/proc/make_action(action_type, target_id = "", text = "", seconds = 0)
	return list("type" = action_type, "target_id" = target_id, "text" = text, "seconds" = seconds)

/datum/unit_test/npcstation/pickup_and_drop/Run()
	var/mob/living/carbon/human/human = allocate(/mob/living/carbon/human/consistent)
	var/datum/ai_controller/npcstation/controller = create_controller(human)
	var/obj/item/wrench/wrench = allocate(/obj/item/wrench, get_step(get_turf(human), EAST))
	var/datum/npcstation_target/known = controller.remember_target(wrench, TRUE)
	TEST_ASSERT(controller.accept_action(make_action(NPCSTATION_ACT_PICK_UP, known.id), "pickup"), "Pickup action was not accepted.")
	human.next_click = -1
	human.next_move = -1
	var/list/result = controller.perform_interaction(controller.current_action, controller.revision)
	TEST_ASSERT_EQUAL(result["status"], NPCSTATION_SUCCESS, "A reachable wrench was not picked up: [result["detail"]]")
	TEST_ASSERT(human.is_holding(wrench), "Pickup reported success without the wrench in a hand.")
	controller.complete_action(result["status"], result["detail"])
	TEST_ASSERT(controller.accept_action(make_action(NPCSTATION_ACT_DROP, known.id), "drop"), "Drop action was not accepted.")
	result = controller.perform_interaction(controller.current_action, controller.revision)
	TEST_ASSERT_EQUAL(result["status"], NPCSTATION_SUCCESS, "Could not drop a held wrench.")
	TEST_ASSERT_EQUAL(wrench.loc, get_turf(human), "Drop reported success without the wrench on the floor.")
	TEST_ASSERT(!human.is_holding(wrench), "Dropped wrench remained held.")
	controller.complete_action(result["status"], result["detail"])
	controller.next_decision_at = INFINITY

/datum/unit_test/npcstation/reach_and_full_hands/Run()
	var/mob/living/carbon/human/human = allocate(/mob/living/carbon/human/consistent)
	var/datum/ai_controller/npcstation/controller = create_controller(human)
	var/obj/item/wrench/wrench = allocate(/obj/item/wrench, get_step(get_step(get_turf(human), EAST), EAST))
	var/datum/npcstation_target/known = controller.remember_target(wrench, TRUE)
	controller.accept_action(make_action(NPCSTATION_ACT_PICK_UP, known.id), "far-pickup")
	var/list/result = controller.perform_interaction(controller.current_action, controller.revision)
	TEST_ASSERT_EQUAL(result["status"], NPCSTATION_FAILURE, "Picked up a wrench out of reach.")
	TEST_ASSERT(isturf(wrench.loc), "Out-of-reach item moved into inventory.")
	controller.complete_action(result["status"], result["detail"])
	wrench.forceMove(get_step(get_turf(human), EAST))
	human.put_in_hands(allocate(/obj/item/crowbar))
	human.put_in_hands(allocate(/obj/item/screwdriver))
	TEST_ASSERT_EQUAL(length(human.get_empty_held_indexes()), 0, "Test did not fill both hands.")
	controller.accept_action(make_action(NPCSTATION_ACT_PICK_UP, known.id), "full-pickup")
	result = controller.perform_interaction(controller.current_action, controller.revision)
	TEST_ASSERT_EQUAL(result["status"], NPCSTATION_FAILURE, "Picked up a wrench with full hands.")
	TEST_ASSERT(isturf(wrench.loc), "Full-hands pickup teleported the wrench.")
	controller.complete_action(result["status"], result["detail"])
	controller.next_decision_at = INFINITY

/datum/unit_test/npcstation/clientless_hearing/Run()
	var/mob/living/carbon/human/human = allocate(/mob/living/carbon/human/consistent)
	human.fully_replace_character_name(human.real_name, "NPC 1")
	var/datum/ai_controller/npcstation/controller = create_controller(human)
	var/mob/living/carbon/human/speaker = allocate(/mob/living/carbon/human/consistent, get_step(get_turf(human), EAST))
	TEST_ASSERT_NULL(GET_CLIENT(human), "The hearing test must use a clientless NPC.")
	human.Hear(speaker, /datum/language/common, "NPC 1, follow me", null, null, null, list(), list(), 7)
	TEST_ASSERT_NOTNULL(controller.directive, "Clientless human did not receive addressed speech.")
	TEST_ASSERT_EQUAL(controller.directive["text"], "follow me", "Wrong directive text.")
	var/original_revision = controller.revision
	ADD_TRAIT(human, TRAIT_DEAF, TRAIT_SOURCE_UNIT_TESTS)
	human.Hear(speaker, /datum/language/common, "NPC 1, secret command", null, null, null, list(), list(), 7)
	TEST_ASSERT_EQUAL(controller.revision, original_revision, "Deaf NPC heard speech.")
	REMOVE_TRAIT(human, TRAIT_DEAF, TRAIT_SOURCE_UNIT_TESTS)
	speaker.forceMove(get_step(get_step(get_turf(human), EAST), EAST))
	human.Hear(speaker, /datum/language/common, "NPC 1, whispered secret", null, null, null, list(), list(WHISPER_MODE = TRUE), 1)
	TEST_ASSERT_EQUAL(controller.revision, original_revision, "NPC received a full out-of-range whisper.")
	human.Hear(speaker, /datum/language/common, "Unaddressed conversation", null, null, null, list(), list(), 7)
	TEST_ASSERT_EQUAL(controller.revision, original_revision, "Unaddressed conversation replaced the directive.")
	human.Hear(speaker, /datum/language/common, "NPC 1, stop", null, null, null, list(), list(), 7)
	TEST_ASSERT_NULL(controller.directive, "Stop command should immediately clear the directive without inference.")
	controller.next_decision_at = INFINITY

/datum/unit_test/npcstation/stale_response_and_takeover/Run()
	var/mob/living/carbon/human/human = allocate(/mob/living/carbon/human/consistent)
	var/datum/ai_controller/npcstation/controller = create_controller(human)
	var/datum/npcstation_request/pending = allocate(/datum/npcstation_request, controller, "old-decision")
	controller.pending_decision_id = pending.decision_id
	controller.interrupt("New instruction.")
	controller.receive_decision(pending)
	TEST_ASSERT_NULL(controller.current_action, "A stale inference response started an action.")
	TEST_ASSERT_NULL(controller.pending_decision_id, "A stale request never released the NPC's inference slot.")
	TEST_ASSERT(!controller.accept_action(make_action(NPCSTATION_ACT_MOVE, "[REF(human)]"), "raw-ref"), "A raw BYOND ref was accepted as a target.")
	controller.accept_action(make_action(NPCSTATION_ACT_WAIT, seconds = 5), "waiting")
	controller.on_sentience_gained()
	TEST_ASSERT_NULL(controller.current_action, "Player takeover did not cancel the action.")
	TEST_ASSERT_EQUAL(controller.ai_status, AI_STATUS_OFF, "Controller remained active after takeover.")
	controller.next_decision_at = INFINITY

/datum/unit_test/npcstation/last_seen_location/Run()
	var/mob/living/carbon/human/human = allocate(/mob/living/carbon/human/consistent)
	var/datum/ai_controller/npcstation/controller = create_controller(human)
	var/obj/item/wrench/wrench = allocate(/obj/item/wrench, get_step(get_turf(human), EAST))
	var/datum/npcstation_target/known = controller.remember_target(wrench, TRUE)
	var/turf/last_turf = known.last_turf
	human.become_blind(TRAIT_SOURCE_UNIT_TESTS)
	wrench.forceMove(run_loc_floor_top_right)
	controller.build_observation()
	TEST_ASSERT_EQUAL(known.last_turf, last_turf, "Unseen item was tracked to its new position.")
	human.cure_blind(TRAIT_SOURCE_UNIT_TESTS)
	TEST_ASSERT(!controller.accept_action(make_action("call_proc", known.id), "arbitrary-proc"), "Unknown executable action was accepted.")

