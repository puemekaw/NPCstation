ADMIN_VERB(spawn_npcstation_crew, R_SPAWN, "Spawn NPC Crew", "Spawn an experimental NPCstation crewmember at your location.", ADMIN_CATEGORY_FUN)
	if(!CONFIG_GET(flag/npcstation_enabled))
		to_chat(user, "Enable NPCSTATION_ENABLED in config/config.txt first.")
		return
	if(SSticker.current_state != GAME_STATE_PLAYING)
		to_chat(user, "Start the round before spawning NPC crew.")
		return
	var/list/roles = list()
	for(var/rank in SSjob.name_occupations)
		var/datum/job/job = SSjob.get_job(rank)
		if(job.job_flags & JOB_CREW_MEMBER)
			roles += rank
	var/rank = tgui_input_list(user, "The first prototype has generic crew skills; the job supplies equipment and access.", "NPC crew job", roles, JOB_ASSISTANT)
	if(isnull(rank))
		return
	var/npc_name = tgui_input_text(user, "Address this NPC by name, for example: NPC 1, follow me", "NPC crew name", "NPC [SSnpcstation.next_agent_id + 1]", max_length = 40)
	var/turf/destination = get_turf(user.mob)
	if(!length(trim(npc_name)) || isnull(destination))
		return
	var/mob/living/carbon/human/crew_member = npcstation_spawn_crew(destination, SSjob.get_job(rank), trim(strip_html(npc_name)))
	if(isnull(crew_member))
		to_chat(user, "Could not spawn NPC crew. Check the configured crew limit and job availability.")
		return
	log_admin("[key_name(user)] spawned NPCstation [crew_member] as [rank].")
	message_admins("[key_name_admin(user)] spawned NPCstation [crew_member] as [rank].")
	to_chat(user, "Spawned [crew_member]. Address commands as '[crew_member.name], follow me' or '[crew_member.name], bring me that wrench'.")

ADMIN_VERB(npcstation_crew_status, R_DEBUG, "NPC Crew Status", "Show NPCstation action and bridge status.", ADMIN_CATEGORY_DEBUG)
	for(var/datum/ai_controller/npcstation/controller as anything in SSnpcstation.crew)
		to_chat(user, "[controller.agent_id]: [controller.pawn] | [controller.bridge_status] | pending: [controller.pending_decision_id || "none"] | revision: [controller.revision]")
	to_chat(user, "[length(SSnpcstation.crew)] NPCs, [length(SSnpcstation.pending_requests)] inference requests in flight.")

/// Uses the established debug crew spawn flow: role, mind, outfit, ID, manifest.
/proc/npcstation_spawn_crew(turf/destination, datum/job/job, npc_name)
	if(!CONFIG_GET(flag/npcstation_enabled) || length(SSnpcstation.crew) >= CONFIG_GET(number/npcstation_max_crew) || isnull(destination) || isnull(job) || !(job.job_flags & JOB_CREW_MEMBER))
		return null
	var/mob/dead/new_player/placeholder = new()
	placeholder.mind_initialize()
	placeholder.mind.name = npc_name
	if(!SSjob.assign_role(placeholder, job, latejoin = TRUE, do_eligibility_checks = FALSE))
		qdel(placeholder)
		return null
	var/mob/living/carbon/human/character = new(destination)
	placeholder.mind.transfer_to(character)
	qdel(placeholder)
	character.fully_replace_character_name(character.real_name, npc_name)
	SSjob.equip_rank(character, job)
	job.after_latejoin_spawn(character)
	SSticker.minds |= character.mind
	GLOB.manifest.inject(character)
	new /datum/ai_controller/npcstation(character)
	return character

