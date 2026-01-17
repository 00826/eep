--!strict

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

--- runs function at second interval `x` for `time` seconds \
--- exceptions: \
--- `x == -1`: function is called every heartbeat \
--- `time == -1`: framerule runs indefinitely
local function framerule(x: number, time: number, f: (dt: number, elapsed: number) -> (), immediate: boolean?): (RBXScriptConnection, thread?)
	if time == -1 then
		local start = os.clock()
		local recent = os.clock()
		if immediate ~= false then
			recent -= x or 1/60 --- doesn't matter
		end

		if x == -1 then
			return RunService.Heartbeat:Connect(function(dt)
				local now = os.clock()
				f(dt, now - start)
			end)
		else
			return RunService.Heartbeat:Connect(function()
				local now = os.clock()
				local dt = now - recent
				if dt > x then
					recent = now - (dt - x)

					f(dt, now - start)
				end
			end)
		end
	else
		local connection = framerule(x, -1, f, immediate)

		return connection, task.delay(time, connection.Disconnect, connection)
	end
end

--- debug trace string
local function trace(s: any?)
	local a, b = debug.info(2, "sl")
	return string.format("[%s:%s]: %s", a, b or "{pcall?}", s or "")
end

--- prints with script name
local function output(...: any)
	print(string.format("[%s]:", script.Name), select(1, ...))
end

local function printtable(t: {[any]: any})
	for k, v in t do
		print(string.format("%s %s:", type(k), k), v)
	end
end

--- ### eep.luauㅤ/ephemeral entrypoint/
--- 
--- [*view eep on github*](https://github.com/00826/eep)
local eep = {
	--- matchmaking task table \
	--- uses datamodelstore to maintain the minimum # of memorystores (queued activities, shared activities, datamodels) \
	--- `pull: 200, expiry: 4, heartbeat: 2`'s worst-case (200) should have a unit cost of ~15060 from a budget of 25000
	matchmakingtask = { --- ඞ
		--- page size that this datamodel, if tasked with queued activity matchmaking, will pull from the activity queue
		pull = 200;
		--- how long this datamodel, if tasked with queued activity matchmaking, have the task to apply matchmaking \
		expiry = 4;
		--- how often will this datamodel, if able to apply matchmaking, attempt to claim the matchmaking task
		heartbeat = 2;

		type = "global" ::
			| "local" --- matchmaking step contained to this server
			| "global"; --- matchmaking step contained to queuedactivitystore
		
		key = "__matchmakingtask";
		value = false;
	};

	--- shared activity queue { [string datamodel guid]: {  } }
	queuedactivitystore = {
		map = nil :: MemoryStoreSortedMap?;
		name = "eep_queue";

		key = "";
		--- `read`: this datamodel \
		--- `limited write`: this datamodel (key, value) \
		--- `read`: activityqueue datamodel \
		--- `limited write`: activityqueue datamodel (accesscode)
		value = {  } :: {
			__timestamp: number;
			[string]: {
				activitykey: string;
				stringuserids: {string};
				
				sharedactivitykey: string;
				accesscode: string;
			}
		};
	};

	--- shared activity
	sharedactivitystore = {
		map = nil :: MemoryStoreHashMap?;
		name = "eep_shared";
		--- x * minutes
		expiry = 5 * (60);
		--- how often will this datamodel update itself to its associated shared activity
		heartbeat = 2;

		key = "";
		--- `read`: this datamodel \
		--- `limited write`: this datamodel (restricted to `instances[datamodelstore.value.index]`)
		value = {  } :: {
			key: string;
			timestamp: number;
			instances: {{
				index: number;
				value: {[any]: any};

				stringuserids: {string};
				timestamp: number;

				privateserverid: string;
				accesscode: string;
			}};
			
			--- index of first instance that "ended" the activity
			concludeindex: number;
			--- timestamp of first instance that "ended" the activity
			concludetimestamp: number;
		};
	};

	datamodelvalueflag = "eep_datamodelvalue";
	--- datamodels, contains activity rulesets and associated shared activity \
	--- values of this hashmap should point to a shared activity key (guid) \
	--- `read`: eep.main() resolve activity step \
	--- `write`: activity instance create \
	--- this never updates, and is only written to when an activity instance is created
	datamodelstore = {
		map = nil :: MemoryStoreHashMap?;
		name = "eep_datamodels";
		--- x * minutes
		expiry = 1 * (60);
		--- never update
		heartbeat = -1;

		key = "";
		--- key-value pairs of datamodel value are in eep.activity (sharedactivitykey, index, key)
		value = {} :: {
			activitykey: string;
			index: number;
			sharedactivitykey: string;
		};
	};

	--- assigned activity value \
	--- `read`: this datamodel \
	--- `write`: depends
	activity = {
		sharedactivitykey = "";
		index = 0;
		indexvalue = {} :: {[any]: any};

		timestamp = 0;

		key = "";
		value = {  } :: {
			name: string;
			desc: string;
			rules: {
				--- what modules will run when `eep.main(...)` is called
				moduleset: string;
				--- will this datamodel run the activity matchmaking job (and also run the queue)
				domatchmakingtask: boolean;
				--- will this datamodel update itself to its associated shared activity
				dosharedactivityrefresh: boolean;
				--- game-specific rules
				[string]: any;
			};
			queue: {
				--- can this activity be queued into
				enabled: boolean;
				--- when this activity is queued, how many servers will be reserved
				instances: number;
				--- # of players to assign to each instance of this activity
				playersperinstance: number;
			};
		};
	};
}

---                         $$\           
---                         \__|          
--- $$$$$$\$$$$\   $$$$$$\  $$\ $$$$$$$\  
--- $$  _$$  _$$\  \____$$\ $$ |$$  __$$\ 
--- $$ / $$ / $$ | $$$$$$$ |$$ |$$ |  $$ |
--- $$ | $$ | $$ |$$  __$$ |$$ |$$ |  $$ |
--- $$ | $$ | $$ |\$$$$$$$ |$$ |$$ |  $$ |
--- \__| \__| \__| \_______|\__|\__|  \__|

--- eep entry point
function eep.main(
	activitymap: { __default: string; [string]: typeof(eep.activity.value); },
	modulesets: { [string]: {ModuleScript} }
)
	local start = os.clock()
	local isserver = RunService:IsServer()

	--- output("eep.main()")

	--- guarantee existence of default activity
	assert(activitymap[activitymap.__default], trace("activitymap must have a non-nil __default value"))

	if isserver then
		--- main/server

		--- bindtoclose
		game:BindToClose(function(closereason: Enum.CloseReason)
			local datamodelkey = eep.datamodelkey(game.PrivateServerId)

			--- removeasync from activity queue
			local queuedactivitysortedmap = eep.queuedactivitystore.map
			if queuedactivitysortedmap and queuedactivitysortedmap:IsA("MemoryStoreSortedMap") then
				local removeasyncsuccess, removeasyncresult = pcall(queuedactivitysortedmap.RemoveAsync, queuedactivitysortedmap, datamodelkey)
				if not removeasyncsuccess then warn(trace(removeasyncresult)) end
			end

			--- removeasync from datamodels
			local datamodelhashmap = eep.datamodelstore.map
			if datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap") then
				local removeasyncsuccess, removeasyncresult = pcall(datamodelhashmap.RemoveAsync, datamodelhashmap, datamodelkey)
				if not removeasyncsuccess then warn(trace(removeasyncresult)) end
			end
		end)

		--- output("resolving datamodel")
		eep.initdatamodelstore(activitymap)
		local datamodelvalue = eep.resolvedatamodelvalue(activitymap)

		--- print("--- datamodelvalue:")
		--- printtable(datamodelvalue)
		--- print("---")

		eep.setactivity(datamodelvalue, activitymap)

		--- output("resolving shared activity")
		eep.initsharedactivitystore(activitymap)
		local sharedactivity = eep.resolvesharedactivity(eep.activity.sharedactivitykey, datamodelvalue.activitykey)
		for k, v in sharedactivity do
			eep.sharedactivitystore.value[k] = v
		end

		local sharedactivitykey = sharedactivity.key
		datamodelvalue.sharedactivitykey = sharedactivitykey

		eep.sharedactivitystore.key = sharedactivitykey
		eep.datamodelstore.value = datamodelvalue

		--- output("init queued activities/matchmaking task")
		--- `datamodel updateasync step -> teleport step -> matchmaking task (allocate teams -> reserve servers -> updateasync relevant datamodel activity hosts with access codes)`
		eep.initqueuedactivitystore(activitymap)
	else
		--- main/client

		--- output("resolving datamodel")
		local datamodelvaluejson = script:GetAttribute(eep.datamodelvalueflag)
		if type(datamodelvaluejson) ~= "string" then
			repeat
				task.wait()
				datamodelvaluejson = script:GetAttribute(eep.datamodelvalueflag)

			until type(datamodelvaluejson) == "string"
		end

		assert(type(datamodelvaluejson) == "string")

		local datamodelvalue: typeof(eep.createdatamodelvalue("", 0))? = HttpService:JSONDecode(datamodelvaluejson)
		assert(type(datamodelvalue) == "table", trace(string.format("expected table, got '%s'", type(datamodelvalue))))

		--- write datamodel value
		eep.setactivity(datamodelvalue, activitymap)
		eep.datamodelstore.value = datamodelvalue
	end

	local activity = eep.activity
	local rules = activity.value.rules
	assert(rules, trace("activityvalue.rules is nil"))
	local modules = modulesets[rules.moduleset]
	assert(modules, trace(string.format("unknown moduleset '%s'", rules.moduleset)))

	--- output(string.format("loading moduleset '%s' (%d modules)", rules.moduleset, #modules), modules)

	for i, modulescript in ipairs(modules) do
		if modulescript:IsA("ModuleScript") then
			local a, module = pcall(require, modulescript)
			if a then
				if type(module) == "table" then
					if module.init and type(module.init) == "function" then
						local b, c = pcall(module.init)
						if not b then warn(trace(c)) end
					end
				end
			else
				warn(modulescript.Name, trace(module))
			end
		else
			warn(i, modulescript.Name)
		end
	end

	if isserver then
		--- let load
		script:SetAttribute(eep.datamodelvalueflag, HttpService:JSONEncode(eep.datamodelstore.value))
	end

	local finish = os.clock() - start
	output(string.format("activity: '%s', sharedactivity: '%s', time: %dms", activity.key, eep.activity.sharedactivitykey or "(nil)", finish * 1000), activity)

	return finish
end

--- sets activity key-value pairs
function eep.setactivity(datamodelvalue: typeof(eep.createdatamodelvalue(...)), activitymap: { __default: string; [string]: typeof(eep.activity.value); })
	local sharedactivitykey = datamodelvalue.sharedactivitykey
	local index = datamodelvalue.index
	local activitykey = datamodelvalue.activitykey
	local activity = activitymap[activitykey]

	local a = eep.activity
	a.index = index
	a.key = activitykey
	a.sharedactivitykey = sharedactivitykey
	a.value = activity

	--- print("--- activity set:")
	--- printtable(a)
	--- print("---")

	return a
end

--- returns `eep.activity.key`
function eep.readactivitykey()
	return eep.activity.key
end

--- returns `eep.activity.value.rules[name]`
function eep.readrule(name: string)
	return eep.activity.value.rules[name]
end

---                                                         $$\                       $$\     $$\            $$\   $$\               
---                                                         $$ |                      $$ |    \__|           \__|  $$ |              
---  $$$$$$\  $$\   $$\  $$$$$$\  $$\   $$\  $$$$$$\   $$$$$$$ | $$$$$$\   $$$$$$$\ $$$$$$\   $$\ $$\    $$\ $$\ $$$$$$\   $$\   $$\ 
--- $$  __$$\ $$ |  $$ |$$  __$$\ $$ |  $$ |$$  __$$\ $$  __$$ | \____$$\ $$  _____|\_$$  _|  $$ |\$$\  $$  |$$ |\_$$  _|  $$ |  $$ |
--- $$ /  $$ |$$ |  $$ |$$$$$$$$ |$$ |  $$ |$$$$$$$$ |$$ /  $$ | $$$$$$$ |$$ /        $$ |    $$ | \$$\$$  / $$ |  $$ |    $$ |  $$ |
--- $$ |  $$ |$$ |  $$ |$$   ____|$$ |  $$ |$$   ____|$$ |  $$ |$$  __$$ |$$ |        $$ |$$\ $$ |  \$$$  /  $$ |  $$ |$$\ $$ |  $$ |
--- \$$$$$$$ |\$$$$$$  |\$$$$$$$\ \$$$$$$  |\$$$$$$$\ \$$$$$$$ |\$$$$$$$ |\$$$$$$$\   \$$$$  |$$ |   \$  /   $$ |  \$$$$  |\$$$$$$$ |
---  \____$$ | \______/  \_______| \______/  \_______| \_______| \_______| \_______|   \____/ \__|    \_/    \__|   \____/  \____$$ |
---       $$ |                                                                                                             $$\   $$ |
---       $$ |                                                                                                             \$$$$$$  |
---       \__|                                                                                                              \______/ 

--- init queued activity memorystore sortedmap
function eep.initqueuedactivitystore(activitymap: { __default: string; [string]: typeof(eep.activity.value); })
	local start = os.clock()
	
	local queuedactivitystore = eep.queuedactivitystore
	queuedactivitystore.map = MemoryStoreService:GetSortedMap(queuedactivitystore.name)
	queuedactivitystore.key = eep.datamodelkey(game.PrivateServerId)

	local queuedactivitysortedmap = queuedactivitystore.map
	assert(queuedactivitysortedmap and queuedactivitysortedmap:IsA("MemoryStoreSortedMap"))

	--- playerremoving remove
	Players.PlayerRemoving:Connect(function(player: Player)
		eep.queuedactivityremovestringuserid(tostring(player.UserId))
	end)

	--- matchmaking task
	local matchmakingtask = eep.matchmakingtask

	local function mmtask()
		local rules = eep.activity.value.rules
		if not rules then return end
		if rules.domatchmakingtask ~= true then return end

		local now = DateTime.now().UnixTimestampMillis

		do --- updateasync this datamodel with locally-queued activities
			if matchmakingtask.type == "local" then
				--- teleports
				local teleportstepsuccess, teleportedstringuserids, time = pcall(eep.queuedactivityteleportstep)
				if teleportstepsuccess then
					--- output(string.format("global matchmaking teleport step took %dms", teleportstepresult * 1000))

					local queuedactivities = eep.queuedactivitystore.value
					--- if teleported, clear from value
					for _, stringuserid in teleportedstringuserids do
						queuedactivities[stringuserid] = nil
					end
				else
					warn(trace(teleportedstringuserids))
				end
			elseif matchmakingtask.type == "global" then
				--- updateasync sorted map with this datamodel
				local updateasyncsuccess, updateasyncresult = pcall(
					queuedactivitysortedmap.UpdateAsync,
					queuedactivitysortedmap,
					queuedactivitystore.key,
					function(value: typeof(queuedactivitystore.value)?): any?
						local queuedactivities = queuedactivitystore.value

						if value and type(value) == "table" then
							local hasnonmatchmadeactivities = false --- indicator that there is a queued activity in this datamodel that has not been matchmade

							--- only insert new ones
							for k, v in queuedactivities do
								if not value[k] and type(v) == "table" then
									value[k] = v
								end
							end

							for cloudhoststringuserid, cloudqueuedactivity in value do
								if type(cloudqueuedactivity) == "table" then
									--- wipe if no longer present
									if not queuedactivities[cloudhoststringuserid] then
										value[cloudhoststringuserid] = nil
									end

									--- write accesscode
									local queuedactivity = queuedactivities[cloudhoststringuserid]
									if queuedactivity then
										local activitykey = queuedactivity.activitykey
										local accesscode = cloudqueuedactivity.accesscode

										queuedactivity.accesscode = accesscode

										if accesscode ~= "" then
											--- matchmade
											
										else
											--- not matchmade
											queuedactivity.activitykey = activitykey

											if activitymap[queuedactivity.activitykey] ~= nil and accesscode == "" then
												hasnonmatchmadeactivities = true
											end
										end
									else
										--- ???
										value[cloudhoststringuserid] = nil
									end
								else
									--- probably __timestamp
								end
							end

							local teleportstepsuccess, teleportedstringuserids, time = pcall(eep.queuedactivityteleportstep)
							if teleportstepsuccess then
								--- output(string.format("global matchmaking teleport step took %dms", teleportstepresult * 1000))

								--- if teleported, clear from value
								for _, stringuserid in teleportedstringuserids do
									value[stringuserid] = nil
									queuedactivities[stringuserid] = nil
								end
							else
								warn(trace(teleportedstringuserids))
							end
							

							if hasnonmatchmadeactivities == true then
								--- print("queue if not dequeued")
								if value.__timestamp <= 0 then
									value.__timestamp = now
								end
							else
								--- print("dequeue")
								value.__timestamp = -1
							end

							return value, value.__timestamp
						else
							--- print("queue")
							queuedactivities.__timestamp = now

							return queuedactivities, queuedactivities.__timestamp
						end
					end,
					eep.datamodelstore.expiry
				)
				if updateasyncsuccess then
					--- ok
				else
					warn(trace(updateasyncresult))
				end
			else
				error(trace(string.format("unknown matchmakingtask.type '%s'", matchmakingtask.type or "nil")))
			end
		end

		do --- resolve matchmaking task
			if matchmakingtask.type == "local" then
				--- do matchmaking
				matchmakingtask.value = true

				--- local matchmaking task
				eep.localmatchmakingtask(activitymap)
			elseif matchmakingtask.type == "global" then
				--- attempt to claim matchmaking task
				matchmakingtask.value = false

				local datamodelhashmap = eep.datamodelstore.map
				if datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap") then
					--- updateasync matchmaking task
					local tasksuccess, taskresult = pcall(
						datamodelhashmap.UpdateAsync,
						datamodelhashmap,
						matchmakingtask.key,
						function(t: {timestamp: number, jobid: string}?): any
							if t == nil or t and t.jobid == game.JobId then
								return { timestamp = DateTime.now().UnixTimestampMillis; jobid = game.JobId; }
							end

							return nil
						end,
						matchmakingtask.expiry
					)
					if tasksuccess then
						matchmakingtask.value = taskresult ~= nil and taskresult.jobid == game.JobId
					else
						warn(trace(taskresult))
					end
				else
					warn(trace("datamodelhashmap is not a memorystorehashmap; this datamodel cannot attempt to claim matchmaking task"))
				end

				--- global matchmaking task
				if matchmakingtask.value == true then
					eep.globalmatchmakingtask(activitymap)
				end
			else
				error(trace(string.format("unknown matchmakingtask.type '%s'", matchmakingtask.type or "nil")))
			end
		end
	end

	framerule(matchmakingtask.heartbeat, -1, mmtask)

	return os.clock() - start
end

--- creates a queued activity
function eep.createqueuedactivity(activitykey: string)
	return {
		activitykey = activitykey;
		stringuserids = {} :: {string};

		sharedactivitykey = "";
		accesscode = "";
	}
end

function eep.addqueuedactivity(hoststringuserid: string, q: typeof(eep.createqueuedactivity(...)))
	eep.queuedactivitystore.value[hoststringuserid] = q
end

function eep.findqueuedactivity(hoststringuserid: string)
	return eep.queuedactivitystore.value[hoststringuserid]
end

function eep.removequeuedactivity(hoststringuserid: string)
	if eep.queuedactivitystore.value[hoststringuserid] then
		eep.queuedactivitystore.value[hoststringuserid] = nil

		return true
	end

	return false
end

--- removes stringuserid from queued activities in this datamodel
function eep.queuedactivityremovestringuserid(stringuserid: string)
	eep.queuedactivitystore.value[stringuserid] = nil

	for k, v in eep.queuedactivitystore.value do
		if type(v) == "table" then
			local stringuserids = v.stringuserids
			for i = #stringuserids, 1, -1 do
				if stringuserids[i] == stringuserid then
					table.remove(stringuserids, i)
				end
			end
		else
			--- __timestamp
		end
	end
end

--- teleports locally-queued players to their updateasync-set reserved server access codes \
--- returns list of teleported string userids to remove from queue
function eep.queuedactivityteleportstep()
	local start = os.clock()
	local teleported = table.create(Players.MaxPlayers)

	for hoststringuserid, queuedactivity in eep.queuedactivitystore.value do
		if type(queuedactivity) == "table" then
			local accesscode = queuedactivity.accesscode
			--- skip if empty string
			if accesscode == "" then continue end
			
			output(string.format("teleporting players %s", table.concat(queuedactivity.stringuserids, ", ")))

			--- stringuserid to player instance
			local players = table.create(#queuedactivity.stringuserids)
			for _, stringuserid in ipairs(queuedactivity.stringuserids) do
				local player = Players:GetPlayerByUserId(tonumber(stringuserid) or 0)
				if player then
					table.insert(players, player)
				end
			end

			--- only if players exist to teleport
			if #players > 0 then
				if RunService:IsStudio() then
					warn("not teleporting (studio instance)")
				else
					--- teleport
					local list = {}
					for _, p in players do
						table.insert(list, tostring(p.UserId))
					end

					local to = Instance.new("TeleportOptions")
					to.ReservedServerAccessCode = accesscode
					local teleportasyncsuccess, teleportasyncresult = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, players, to)

					if teleportasyncsuccess then
						output(string.format("teleporting %s to %s", table.concat(queuedactivity.stringuserids, ", "), accesscode))
						table.move(list, 1, #list, #teleported + 1, teleported)
					else
						warn(trace(teleportasyncresult))
					end
				end
			end
		else
			--- __timestamp
		end
	end

	return teleported, os.clock() - start
end

--- from `queuedactivitystore.sortedmap:getrangeasync()` return value: \
--- sends each queued activity into a "bucket" \
--- for each bucket, attempts to allocate instances and teams that fit the queued activity \
--- from only correctly-allocated teams, creates and reserves servers for the queued activity \
--- returns `manifest {[string datamodelkey]: {[string hostuserid]: string reservedserveraccesscode}}` to updateasync relevant datamodels and their hosts
function eep.queuedactivitymatchmakingstep(getrangeasyncresult: typeof(eep.queuedactivityvaluetosortedmaprange()), activitymap: { __default: string; [string]: typeof(eep.activity.value); })
	local manifest = {};

	local activitybucket = {};
	local queuedforactivitycount = {};

	--- resolve queued activities
	for i, rangevalue in ipairs(getrangeasyncresult) do
		local datamodelkey = rangevalue.key
		local datamodelqueuedactivities = rangevalue.value

		for hoststringuserid, queuedactivity in datamodelqueuedactivities do
			if type(queuedactivity) ~= "table" then continue end --- skip timestamp
			--- do not consider if accesscode points to a server
			if queuedactivity.accesscode ~= "" then continue end

			--- do not consider if activity is not an actual activity
			local activitykey = queuedactivity.activitykey
			if activitykey == "" then continue end
			if not activitymap[activitykey] then continue end

			if not activitybucket[activitykey] then
				activitybucket[activitykey] = table.create(200)
			end
			if not queuedforactivitycount[activitykey] then
				queuedforactivitycount[activitykey] = 0
			end

			--- print(hoststringuserid, queuedactivity)

			table.insert(activitybucket[activitykey], { datamodelkey = datamodelkey; hoststringuserid = hoststringuserid; stringuserids = queuedactivity.stringuserids; })
			queuedforactivitycount[activitykey] += #queuedactivity.stringuserids
		end
	end

	--- create shared activity for each queued activity
	for activitykey, list in activitybucket do
		local activity = activitymap[activitykey]
		if activity then
			if activity.queue.enabled ~= true then continue end

			local instances = activity.queue.instances
			local playersperinstance = activity.queue.playersperinstance

			--- print(activitykey, queuedforactivitycount[activitykey], "/", instances * playersperinstance)

			local required = instances * playersperinstance
			if (queuedforactivitycount[activitykey] or 0) < required then continue end

			--- allocate teams
			local teams = table.create(instances)
			local teamhosts = {}

			for t = 1, instances do
				local team = table.create(playersperinstance)
				local indices = table.create(playersperinstance)
				
				--- allocate
				for i, listing in ipairs(list) do
					local datamodelkey = listing.datamodelkey
					local hoststringuserid = listing.hoststringuserid
					local stringuserids = listing.stringuserids
					local len = #stringuserids

					--- print(string.format("considering party of size %d {%s}", len, table.concat(stringuserids, ", ")))

					if #team + len <= playersperinstance then
						--- move players
						table.move(stringuserids, 1, len, #team + 1, team)
						table.insert(indices, i)

						--- add to host list
						if not teamhosts[datamodelkey] then
							teamhosts[datamodelkey] = {}
						end
						teamhosts[datamodelkey][hoststringuserid] = t
					end
				end

				--- this is so that after this loop, #team == instances if and only if each team has the exect # of players
				if #team == playersperinstance then
					--- remove listings
					for i = #indices, 1, -1 do
						table.remove(list, indices[i])
					end

					teams[t] = team
				else
					break
				end
			end

			--- if and only if #teams == instances
			if #teams == instances then
				--- sharedactivity
				local sharedactivity, setasyncsuccess = eep.createsharedactivity(activitykey, instances)
				if not setasyncsuccess then continue end

				output(string.format("created shared activity '%s' with %d instances: %s", activitykey, instances, sharedactivity.key))

				--- move stringuserids
				for i, instance in ipairs(sharedactivity.instances) do
					local stringuserids = teams[i]
					table.move(stringuserids, 1, #stringuserids, 1, instance.stringuserids)
				end

				--- write to host access codes
				for datamodelkey, hoststringuserids in teamhosts do
					for hoststringuserid, index in hoststringuserids do
						local accesscode = sharedactivity.instances[index].accesscode

						if not manifest[datamodelkey] then
							manifest[datamodelkey] = {}
						end
						manifest[datamodelkey][hoststringuserid] = accesscode
					end
				end
			else
				--- couldnt allocate
			end
		else
			warn(trace(string.format("unknown activity '%s'", activitykey)))
		end
	end

	return manifest
end

--- returns `eep.queuedactivitystore.value` normalized as a `queuedactivitysortedmap:GetRangeAsync()` return value
function eep.queuedactivityvaluetosortedmaprange()
	local queuedactivitystore = eep.queuedactivitystore

	return {{
		sortKey = DateTime.now().UnixTimestampMillis;
		key = eep.datamodelkey(game.PrivateServerId);
		value = queuedactivitystore.value;
	}}
end

function eep.localmatchmakingtask(activitymap: { __default: string; [string]: typeof(eep.activity.value); })	
	local queuedactivitystore = eep.queuedactivitystore
	local getrangeasyncresult = eep.queuedactivityvaluetosortedmaprange()

	local manifest = eep.queuedactivitymatchmakingstep(getrangeasyncresult, activitymap)
	--- print("localmatchmakingstep manifest:", manifest)

	for datamodelkey, hoststringaccesscodes in manifest do
		if queuedactivitystore.key == datamodelkey then
			for hoststringuserid, accesscode in hoststringaccesscodes do
				local queuedactivity = queuedactivitystore.value[hoststringuserid]
				if queuedactivity then
					queuedactivity.accesscode = accesscode
				else
					warn(trace("missing queued activity"))
				end
			end
		end
	end
end

function eep.globalmatchmakingtask(activitymap: { __default: string; [string]: typeof(eep.activity.value); })
	local matchmakingtask = eep.matchmakingtask

	local queuedactivitystore = eep.queuedactivitystore
	local queuedactivitysortedmap = queuedactivitystore.map
	assert(queuedactivitysortedmap and queuedactivitysortedmap:IsA("MemoryStoreSortedMap"))

	--- attempt actual task
	local getrangeasyncsuccess, getrangeasyncresult: {{
		sortKey: number; --- unixtimestampmillis
		key: string; --- datamodelkey
		value: typeof(queuedactivitystore.value); --- queuedactivity
	}} = pcall(queuedactivitysortedmap.GetRangeAsync, queuedactivitysortedmap, Enum.SortDirection.Ascending, matchmakingtask.pull, { sortKey = 0; })
	if getrangeasyncsuccess and getrangeasyncresult then
		--- print(#getrangeasyncresult, getrangeasyncresult)
		--- resolve manifest
		local manifest = eep.queuedactivitymatchmakingstep(getrangeasyncresult, activitymap)
		--- print("queuedactivitymatchmakingstep manifest:", manifest)

		--- updateasync hosts with access codes
		for datamodelkey, hoststringaccesscodes in manifest do
			local updateasyncsuccess, updateasyncresult = pcall(
				queuedactivitysortedmap.UpdateAsync,
				queuedactivitysortedmap,
				datamodelkey,
				function(value: typeof(queuedactivitystore.value)?): any
					if value and type(value) == "table" then
						--- print(value)
						for cloudhoststringuserid, cloudqueuedactivity in value do
							--- print(cloudhoststringuserid, cloudqueuedactivity)
							if type(cloudqueuedactivity) == "table" then
								if cloudqueuedactivity.accesscode == "" then
									cloudqueuedactivity.accesscode = hoststringaccesscodes[cloudhoststringuserid] or ""
								end
							end
						end

						return value
					else
						return nil
					end
				end,
				eep.datamodelstore.expiry
			)
			if updateasyncsuccess then
				--- output("success updateasync hosts with relevant access codes")
			else
				warn(trace(updateasyncresult))
			end
		end
	else
		--- getrangeasync error
		warn(trace(getrangeasyncresult))
	end
end

---           $$\                                           $$\                       $$\     $$\            $$\   $$\               
---           $$ |                                          $$ |                      $$ |    \__|           \__|  $$ |              
---  $$$$$$$\ $$$$$$$\   $$$$$$\   $$$$$$\   $$$$$$\   $$$$$$$ | $$$$$$\   $$$$$$$\ $$$$$$\   $$\ $$\    $$\ $$\ $$$$$$\   $$\   $$\ 
--- $$  _____|$$  __$$\  \____$$\ $$  __$$\ $$  __$$\ $$  __$$ | \____$$\ $$  _____|\_$$  _|  $$ |\$$\  $$  |$$ |\_$$  _|  $$ |  $$ |
--- \$$$$$$\  $$ |  $$ | $$$$$$$ |$$ |  \__|$$$$$$$$ |$$ /  $$ | $$$$$$$ |$$ /        $$ |    $$ | \$$\$$  / $$ |  $$ |    $$ |  $$ |
---  \____$$\ $$ |  $$ |$$  __$$ |$$ |      $$   ____|$$ |  $$ |$$  __$$ |$$ |        $$ |$$\ $$ |  \$$$  /  $$ |  $$ |$$\ $$ |  $$ |
--- $$$$$$$  |$$ |  $$ |\$$$$$$$ |$$ |      \$$$$$$$\ \$$$$$$$ |\$$$$$$$ |\$$$$$$$\   \$$$$  |$$ |   \$  /   $$ |  \$$$$  |\$$$$$$$ |
--- \_______/ \__|  \__| \_______|\__|       \_______| \_______| \_______| \_______|   \____/ \__|    \_/    \__|   \____/  \____$$ |
---                                                                                                                        $$\   $$ |
---                                                                                                                        \$$$$$$  |
---                                                                                                                         \______/ 

--- init shared activity memorystore hashmap
function eep.initsharedactivitystore(activitymap: { __default: string; [string]: typeof(eep.activity.value); })
	local start = os.clock()

	local sharedactivitystore = eep.sharedactivitystore
	sharedactivitystore.map = MemoryStoreService:GetHashMap(sharedactivitystore.name)
	sharedactivitystore.key = eep.activity.sharedactivitykey

	local sharedactivityhashmap = sharedactivitystore.map
	assert(sharedactivityhashmap and sharedactivityhashmap:IsA("MemoryStoreHashMap"))

	local function satask()
		local rules = eep.activity.value.rules
		if not rules then return end
		if rules.dosharedactivityrefresh ~= true then return end

		local activity = eep.activity
		local sharedactivitykey = activity.sharedactivitykey
		local index = activity.index

		--- skip if index is 0 or sharedactivitykey is ""
		if sharedactivitykey == "" then return end
		if index == 0 then return end

		local now = DateTime.now().UnixTimestampMillis
		
		--- updateasync
		local updateasyncsuccess, updateasyncresult = pcall(
			sharedactivityhashmap.UpdateAsync,
			sharedactivityhashmap,
			sharedactivitykey,
			function(sharedactivity: typeof(eep.createsharedactivity("", 0))?): any
				if sharedactivity then
					--- print("--- sharedactivity updateasync:", sharedactivitykey)
					--- printtable(sharedactivity)
					--- print("---")
					--- "push up"
					local a, b = pcall(function()
						local cloudinstance = sharedactivity.instances[index]
						if cloudinstance then
							--- write timestamp
							cloudinstance.timestamp = now
							activity.timestamp = now

							--- write index value
							cloudinstance.value = activity.indexvalue

							--- write present players
							--- compose present userids
							local presentstringuserids = table.create(Players.MaxPlayers)
							for _, player in Players:GetPlayers() do
								table.insert(presentstringuserids, tostring(player.UserId))
							end

							local cloudstringuserids = cloudinstance.stringuserids

							--- clear absent
							--- do not do this for review purposes
							--- for i = #cloudstringuserids, 1, -1 do
							--- 	local stringuserid = cloudstringuserids[i]
							--- 	if not Players:GetPlayerByUserId(tonumber(stringuserid) or 1) then
							--- 		table.remove(cloudstringuserids, i)
							--- 	end
							--- end

							--- insert non-inserted
							for i, stringuserid in ipairs(presentstringuserids) do
								if not table.find(cloudstringuserids, stringuserid) then
									table.insert(cloudstringuserids, stringuserid)
								end
							end

							cloudinstance.stringuserids = cloudstringuserids
						else
							--- warn(trace(string.format("instance doesnt exist in shared activities? index: %d", index)))
						end
					end)
					if not a then warn(trace(b)) end

					--- "pull down"
					local c, d = pcall(function()
						for k, v in sharedactivity do
							sharedactivitystore.value[k] = v
						end
					end)
					if not c then warn(trace(d)) end

					return sharedactivity
				else
					return nil
				end
			end,
			sharedactivitystore.expiry
		)
		if updateasyncsuccess then
			--- output("resynced")
		else
			warn(trace(updateasyncresult))
		end
	end

	framerule(sharedactivitystore.heartbeat, -1, satask)

	return os.clock() - start
end

--- creates a shared activity
function eep.createsharedactivity(activitykey: string, instances: number)
	local sharedactivitykey = HttpService:GenerateGUID(false)

	local sharedactivityhashmap = eep.sharedactivitystore.map
	assert(sharedactivityhashmap and sharedactivityhashmap:IsA("MemoryStoreHashMap"))

	local datamodelhashmap = eep.datamodelstore.map
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"))

	--- base shared activity
	local sharedactivityvalue = {
		key = sharedactivitykey;
		timestamp = DateTime.now().UnixTimestampMillis;
		instances = table.create(instances);

		--- index of first instance that "ended" the activity
		concludeindex = -1;
		--- timestamp of first instance that "ended" the activity
		concludetimestamp = -1;
	}

	--- activity instances
	for i = 1, instances do
		local accesscode, privateserverid = "", ""

		if RunService:IsStudio() then
			warn(trace("studio session eep.createactivityinstance(): servers will not be reserved; instance.privateserverid and instance.accesscode will be empty strings ''"))
		else
			accesscode, privateserverid = TeleportService:ReserveServerAsync(game.PlaceId)
		end

		table.insert(sharedactivityvalue.instances, {
			index = i;
			value = {} :: {[string]: any};

			--- string userids expected to be present in the datamodel associated with this shared activity instance
			stringuserids = {} :: {string};
			--- instance "pulse"
			timestamp = 0;

			privateserverid = privateserverid;
			accesscode = accesscode;
		})

		--- setasync datamodel value
		local datamodelkey = eep.datamodelkey(privateserverid)
		local datamodelvalue = eep.createdatamodelvalue(activitykey, i)
		datamodelvalue.sharedactivitykey = sharedactivitykey
		datamodelvalue.index = i

		local setasyncsuccess, setasyncresult = pcall(datamodelhashmap.SetAsync, datamodelhashmap, datamodelkey, datamodelvalue, eep.datamodelstore.expiry)
		if setasyncsuccess then
			--- output(string.format("created activity instance #%d (key: '%s', accesscode: '%s')", i, datamodelkey, accesscode), datamodelvalue)
		else
			warn(trace(setasyncresult))
		end
	end

	--- setasync shared activity
	local setasyncsuccess, setasyncresult = pcall(sharedactivityhashmap.SetAsync, sharedactivityhashmap, sharedactivitykey, sharedactivityvalue, eep.sharedactivitystore.expiry)
	if setasyncsuccess then
		--- output(string.format("created shared activity '%s' (shared activity key: '%s')", activitykey, sharedactivitykey))
	else
		warn(trace(setasyncresult))
	end

	return sharedactivityvalue, setasyncsuccess
end

function eep.resolvesharedactivity(sharedactivitykey: string, activitykey: string)
	local sharedmap = eep.sharedactivitystore.map
	assert(sharedmap and sharedmap:IsA("MemoryStoreHashMap"))

	if sharedactivitykey == "" then
		output("resolvesharedactivity() case: empty string")
		return eep.createsharedactivity(activitykey, 1)
	else
		local getasyncsuccess, getasyncresult: typeof(eep.createsharedactivity(activitykey, 0))? = pcall(sharedmap.GetAsync, sharedmap, sharedactivitykey)
		if getasyncsuccess then
			if type(getasyncresult) == "table" then
				output("resolvesharedactivity() case: getasync")
				--- output("using eep shared activity")

				return getasyncresult, true
			else
				output("resolvesharedactivity() case:", string.format("using dummy shared activity (expected table, got %s)", type(getasyncresult)))

				return eep.createsharedactivity(activitykey, 1)
			end
		else
			output("resolvesharedactivity() case:", string.format("using dummy shared activity (%s)", getasyncresult::any))

			return eep.createsharedactivity(activitykey, 1)
		end
	end
end

--- attempts to conclude shared activity associated with the datamodel calling this function
function eep.concludesharedactivity()
	local result = {
		--- updateasyncsuccess
		success = false;
		index = -1;
		timestamp = -1;
		sharedactivitykey = eep.activity.sharedactivitykey;
	}

	local now = DateTime.now().UnixTimestampMillis

	local sharedactivityhashmap = eep.sharedactivitystore.map
	assert(sharedactivityhashmap and sharedactivityhashmap:IsA("MemoryStoreHashMap"))

	local activity = eep.activity

	local updateasyncsuccess, updateasyncresult = pcall(
		sharedactivityhashmap.UpdateAsync,
		sharedactivityhashmap,
		activity.sharedactivitykey,
		function(sharedactivity: typeof(eep.createsharedactivity("", 0))?): any
			if sharedactivity then
				if sharedactivity.concludeindex == -1 and sharedactivity.concludetimestamp == -1 then
					sharedactivity.concludeindex = activity.index
					sharedactivity.concludetimestamp = now

					--- immediate resync
					local sharedconcludeinstance = sharedactivity.instances[activity.index]
					sharedconcludeinstance.value = activity.indexvalue

					--- print("resynced:")
					--- printtable(sharedconcludeinstance)
					--- print("---")
					--- print("instancevalue:")
					--- printtable(sharedconcludeinstance.value)
					--- print("---")

					result.index = activity.index
					result.timestamp = now

					return sharedactivity
				else
					result.index = sharedactivity.concludeindex
					result.timestamp = sharedactivity.concludetimestamp

					return nil
				end
			else
				return nil
			end
		end,
		eep.sharedactivitystore.expiry
	)

	result.success = updateasyncsuccess

	if updateasyncsuccess then
		output("concluded shared activity:", result, result.sharedactivitykey)
		printtable(result::any) --- for some reason if not casted to any, adds {[any]: any} to result typing
	else
		warn(trace(updateasyncresult))
	end

	return result
end

---       $$\            $$\                                             $$\           $$\ 
---       $$ |           $$ |                                            $$ |          $$ |
---  $$$$$$$ | $$$$$$\ $$$$$$\    $$$$$$\  $$$$$$\$$$$\   $$$$$$\   $$$$$$$ | $$$$$$\  $$ |
--- $$  __$$ | \____$$\\_$$  _|   \____$$\ $$  _$$  _$$\ $$  __$$\ $$  __$$ |$$  __$$\ $$ |
--- $$ /  $$ | $$$$$$$ | $$ |     $$$$$$$ |$$ / $$ / $$ |$$ /  $$ |$$ /  $$ |$$$$$$$$ |$$ |
--- $$ |  $$ |$$  __$$ | $$ |$$\ $$  __$$ |$$ | $$ | $$ |$$ |  $$ |$$ |  $$ |$$   ____|$$ |
--- \$$$$$$$ |\$$$$$$$ | \$$$$  |\$$$$$$$ |$$ | $$ | $$ |\$$$$$$  |\$$$$$$$ |\$$$$$$$\ $$ |
---  \_______| \_______|  \____/  \_______|\__| \__| \__| \______/  \_______| \_______|\__|

--- init datamodel memorystore hashmap
function eep.initdatamodelstore(activitymap: { __default: string; [string]: typeof(eep.activity.value); })
	local start = os.clock()

	local datamodelstore = eep.datamodelstore
	datamodelstore.map = MemoryStoreService:GetHashMap(datamodelstore.name)
	datamodelstore.key = eep.datamodelkey(game.PrivateServerId)
	local datamodelhashmap = datamodelstore.map
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"))

	return os.clock() - start
end

--- creates a datamodel value \
--- "the bare minimum that an instanced activity needs to run"
function eep.createdatamodelvalue(activitykey: string, index: number)
	return {
		activitykey = activitykey;
		sharedactivitykey = "";
		index = index;
	}
end

--- returns matchmakingtype-suffixed string
function eep.datamodelkey(privateserverid: string)
	return privateserverid .. "_" .. tostring(game.MatchmakingType.Value)
end

--- resolves the datamodel value for this datamodel
function eep.resolvedatamodelvalue(activitymap: { __default: string; [string]: typeof(eep.activity.value); })
	if game.PrivateServerId == "" then
		--- output("using dummy datamodel value (public server)")

		return eep.createdatamodelvalue(activitymap.__default, 1)
	else
		local key = eep.datamodelkey(game.PrivateServerId)

		local datamodelmap = eep.datamodelstore.map
		assert(datamodelmap and datamodelmap:IsA("MemoryStoreHashMap"))

		local getasyncsuccess, getasyncresult: typeof(eep.createdatamodelvalue("", 0))? = pcall(datamodelmap.GetAsync, datamodelmap, key)
		if getasyncsuccess then
			if type(getasyncresult) == "table" then
				--- output("using eep datamodel value")

				return getasyncresult
			else
				--- output(string.format("using dummy datamodel value (expected table, got %s)", type(getasyncresult)))
				
				return eep.createdatamodelvalue(activitymap.__default, 1)
			end
		else
			--- output(string.format("using dummy datamodel value (%s)", getasyncresult::any))
			
			return eep.createdatamodelvalue(activitymap.__default, 1)
		end
	end
end

return eep