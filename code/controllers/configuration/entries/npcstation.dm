/// Opt in locally; upstream games do not spawn NPC crew or contact the bridge.
/datum/config_entry/flag/npcstation_enabled

/datum/config_entry/string/npcstation_bridge_url
	default = "http://127.0.0.1:8088"
	protection = CONFIG_ENTRY_LOCKED

/datum/config_entry/string/npcstation_bridge_url/ValidateAndSet(str_val)
	var/static/regex/loopback_url = regex("^http://(127\\.0\\.0\\.1|localhost):[0-9]{1,5}$")
	if(!loopback_url.Find(str_val))
		return FALSE
	var/port = text2num(copytext(str_val, findlasttext(str_val, ":") + 1))
	return port >= 1 && port <= 65535 && ..(str_val)

/datum/config_entry/number/npcstation_max_crew
	default = 8
	min_val = 1
	max_val = 16

/datum/config_entry/number/npcstation_max_requests
	default = 2
	min_val = 1
	max_val = 4

/datum/config_entry/number/npcstation_request_timeout
	default = 20
	min_val = 2
	max_val = 60

