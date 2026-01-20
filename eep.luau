--!strict

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local isserver = RunService:IsServer()
local isstudio = RunService:IsStudio()

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

local function scriptname()
	return string.format("[%s]:", script.Name)
end

--- ### eep.luauㅤ/ephemeral entrypoint/
--- 
--- [*view eep on github*](https://github.com/00826/eep) \
--- timestamps are in `DateTime.now().UnixTimestampMillis`
local eep = {
	activity = {
		key = "";
		value = {  } :: {
			name: string;
			desc: string;
			rules: {
				--- ## datamodel settings
				--- what modules will run when `eep.main(...)` is called
				moduleset: string;
				--- will this datamodel run the activity matchmaking job (and also run the queue)
				domatchmakingtask: boolean;
				--- will this datamodel update itself to its associated shared instance
				dosharedinstancerefresh: boolean;

				--- ## activity settings
				--- can this activity be queued for
				canqueue: boolean;
				--- when this activity is queued, how many peers will be created
				sharedinstancepeers: number;
				--- how many players will be allocated into each shared instance peer
				sharedinstanceuseridsperpeer: number;

				--- ## game-specific rules
				[string]: any;
			};
		};
	};
	--- datamodelstore is never updated
	--- and is a one-time shabang that that gets pulled
	--- on datamodel init
	datamodel = {
		--- memorystore
		store = {
			key = "eep_datamodels";
			value = nil :: MemoryStoreHashMap?;
			expiry = 1 * (60);
			heartbeat = 0;
		};

		key = ""; --- typeof(eep.datamodelkey(game.PrivateServerId))
	};
	--- {[string datamodelkey] = typeof(eep.createsharedinstance(...))}
	--- &
	--- {[string eep.matchmakingtask.key] = }
	sharedinstance = {
		--- memorystore
		store = {
			key = "eep_sharedinstances";
			value = nil :: MemoryStoreHashMap?;
			expiry = 1 * (60);
			heartbeat = 2;
		};

		peerindex = -1;
		peervalue = {};

		key = "";
		value = {} :: {
			--- activity key for this sharedinstance
			activitykey: string;

			--- unique identifier (guid) for this sharedinstance
			key: string;
			--- unix timestamp, in milliseconds, of when this sharedinstance was instantiated
			timestamp: number;

			--- peerindex of peer that concluded this sharedinstance
			concludeindex: number;
			--- unix timestamp, in milliseconds, of when this sharedinstance was concluded
			concludetimestamp: number;

			--- peers
			peers: {
				{
					--- index of this peer relative to the sharedinstance
					index: number;
					--- variable read-write table for game-specific code
					value: {  };
					--- last time this peer was resynced
					timestamp: number;

					--- userids allocated to this peer
					expectinguserids: {number};
					--- party keys associated with this peer
					--- (technically they get dissolved when teleported but exists for posterity)
					partykeys: {string};

					--- reservedserver accesscode
					accesscode: string;
					--- reservedserver privateserverid
					privateserverid: string;
				}
			};
		};

		emptyreserveserverstring = "~";
	};

	party = {
		--- memorystore
		store = {
			key = "eep_parties";
			value = nil :: MemoryStoreSortedMap?;
			expiry = 4;
			heartbeat = 2;
			pull = 200;
			exclusivelowerbound = { sortKey = 0; };

			tasktype = "global" ::
				| "local" --- matchmaking step contained to this server
				| "global"; --- matchmaking step contained to partystore
			
			talkingstickkey = "__talkingstick" .. "_" .. tostring(game.MatchmakingType.Value);
			talkingstickvalue = false;
		};

		--- parties in this datamodel
		value = {} :: {
			{
				--- ## datamodel-prescribed
				--- party guid, is basically an "anchor" in cases where the host leaves
				key: string;
				--- array of userids that are a part of this party
				userids: {number};
				--- array of userids that have been invited to this party
				invites: {number};
				--- queued activity key
				activitykey: string;

				--- ## memorystore-prescribed
				--- timestamp of when this party was added to the queue
				timestamp: number;
				--- reservedserveraccesscode
				accesscode: string;
			}
		};

		maxuserids = 4;
		maxinvites = 4;
	};

	assertions = {
		nostudioactivity = "activitymap must have a non-nil '__studioactivity' key-value pair";
		nodefaultactivity = "activitymap must have a non-nil '__defaultactivity' key-value pair";
		datamodelvalueresolveerror = "error resolving datamodelvalue, will use activitymap __default activity";
		baddatamodelmemorystore = "datamodel memorystore is nil or not a memorystorehashmap";
		badsharedinstancememorystore = "sharedinstance memorystore is nil or not a memorystorehashmap";
		badpartymemorystore = "party memorystore is nil or not a memorystoresortedmap";
		badcreatereceiptenvironment = "eep.createreceipt() can only be called on server";
		badjsonreceipt = "jsonreceipt is not a string";
		baddecodedjsonreceipt = "decoded jsonreceipt is not a table";
		badactivityrules = "activity rules are nil or not a table";
		badactivitymoduleset = "activity moduleset is nil or not a table";
		badmodulescript = "modulescript in moduleset is not a modulescript";
	};

	jsonflag = "eep_receipt";
}

---                         $$\             $$$\ $$$\   
---                         \__|           $$  _| \$$\  
--- $$$$$$\$$$$\   $$$$$$\  $$\ $$$$$$$\  $$  /    \$$\ 
--- $$  _$$  _$$\  \____$$\ $$ |$$  __$$\ $$ |      $$ |
--- $$ / $$ / $$ | $$$$$$$ |$$ |$$ |  $$ |$$ |      $$ |
--- $$ | $$ | $$ |$$  __$$ |$$ |$$ |  $$ |\$$\     $$  |
--- $$ | $$ | $$ |\$$$$$$$ |$$ |$$ |  $$ | \$$$\ $$$  / 
--- \__| \__| \__| \_______|\__|\__|  \__|  \___|\___/  
---                                                     
---                                                     
---                                                     

--- server/client entrypoint
function eep.main(
	activitymap: { __studioactivity: string; __defaultactivity: string; [string]: typeof(eep.activity.value); },
	modulesets: { [string]: { ModuleScript }; }
)
	local start = DateTime.now().UnixTimestampMillis

	--- guarantee existence of default activities
	assert(activitymap[activitymap.__studioactivity], eep.assertions.nostudioactivity)
	assert(activitymap[activitymap.__defaultactivity], eep.assertions.nodefaultactivity)

	if isserver then
		--- bindtoclose removeasyncs
		game:BindToClose(function(closereason: Enum.CloseReason)
			local datamodelkey = eep.datamodelkey(game.PrivateServerId)

			--- removeasync from matchmaking
			local partysortedmap = eep.party.store.value
			if partysortedmap and partysortedmap:IsA("MemoryStoreSortedMap") then
				for _, p in eep.party.value do
					local removeasyncsuccess, removeasyncresult = pcall(partysortedmap.RemoveAsync, partysortedmap, p.key)
					if removeasyncsuccess then
						--- ok
					else
						warn(scriptname(), "bindtoclose partysortedmap removeasync error:", removeasyncresult)
					end
				end
			end

			--- removeasync from datamodels
			local datamodelhashmap = eep.datamodel.store.value
			if datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap") and datamodelkey ~= "" then
				local removeasyncsuccess, removeasyncresult = pcall(datamodelhashmap.RemoveAsync, datamodelhashmap, datamodelkey)
				if removeasyncsuccess then
					--- ok
				else
					warn(scriptname(), "bindtoclose datamodelhashmap removeasync error:", removeasyncresult)
				end
			end
		end)

		--- playerremoving remove userid from parties
		Players.PlayerRemoving:Connect(function(player: Player)
			local userid = player.UserId
			local stringuserid = tostring(player.UserId)

			if eep.party[stringuserid] then
				eep.party[stringuserid] = nil

				local partysortedmap = eep.party.store.value
				if partysortedmap and partysortedmap:IsA("MemoryStoreSortedMap") then
					local removeasyncsuccess, removeasyncresult = pcall(partysortedmap.RemoveAsync, partysortedmap, stringuserid)
					if removeasyncsuccess then
						--- ok
					else
						warn(scriptname(), "playerremoving removeasync error:", removeasyncresult)
					end
				end
			end
			
			eep.partyclear(userid)
			eep.partyclearemptyparties()
		end)

		--- write datamodel key
		eep.datamodel.key = eep.datamodelkey(game.PrivateServerId)

		--- start all heartbeats (also inits their associated memorystores)
		eep.sharedinstancestoreheartbeat()
		eep.datamodelheartbeat()
		eep.partyheartbeat(activitymap)

		--- keys
		local activitykey = activitymap.__defaultactivity
		local sharedinstancekey = ""

		--- resolve datamodel value, write to this table
		local datamodelsuccess, datamodelvalue = eep.datamodelresolve()

		if datamodelsuccess and datamodelvalue then
			activitykey = datamodelvalue.activitykey
			sharedinstancekey = datamodelvalue.sharedinstancekey

		elseif isstudio then
			activitykey = activitymap.__studioactivity
			sharedinstancekey = ""

		elseif game.PrivateServerId == "" then
			activitykey = activitymap.__defaultactivity
			sharedinstancekey = ""

		else
			warn(scriptname(), "eep.datamodelresolve() error", datamodelvalue, "default activity will be used")

			activitykey = activitymap.__defaultactivity
			sharedinstancekey = ""

		end

		eep.activitywrite(activitykey, activitymap[activitykey])

		--- resolve shared instance
		local sharedinstance, index, peer = nil, nil, nil

		local sharedinstancesuccess, sharedinstancevalue = eep.sharedinstanceresolve(sharedinstancekey)
		if sharedinstancesuccess and sharedinstancevalue then
			sharedinstance = sharedinstancevalue
		else
			print(scriptname(), "using placeholder sharedinstance")
			sharedinstance = eep.createsharedinstance(activitykey, eep.activityreadrule("sharedinstancepeers") or 1)
		end
		
		index, peer = eep.sharedinstancefindpeer(sharedinstance, game.PrivateServerId)
		
		--- reassign sharedinstancekey from shared instance for extra safety
		sharedinstancekey = sharedinstance.key
		eep.sharedinstance.key = sharedinstancekey
		eep.sharedinstance.peerindex = index or -1
	else
		--- wait for jsonreceipt to be set
		local jsonreceipt = script:GetAttribute(eep.jsonflag)
		if type(jsonreceipt) ~= "string" then
			repeat
				task.wait()
				jsonreceipt = script:GetAttribute(eep.jsonflag)
			until type(jsonreceipt) ~= "string"
		end
		assert(type(jsonreceipt) == "string", eep.assertions.badjsonreceipt)

		local receipt: typeof(eep.createreceipt())? = HttpService:JSONDecode(jsonreceipt)
		assert(type(receipt) == "table", eep.assertions.baddecodedjsonreceipt)
		
		--- write activitykey, sharedinstance key, sharedinstance peer index
		local activitykey = receipt.activitykey
		eep.activitywrite(activitykey, activitymap[activitykey])
		
		eep.sharedinstance.key = receipt.sharedinstancekey
		eep.sharedinstance.peerindex = receipt.peerindex
	end

	--- one-time ordered require
	local activity = eep.activity
	local rules = activity.value.rules
	assert(rules, eep.assertions.badactivityrules)
	local modules = modulesets[rules.moduleset]
	assert(modules, eep.assertions.badactivitymoduleset)

	--- one time ordered require
	for i, modulescript in ipairs(modules) do
		assert(modulescript:IsA("ModuleScript"), eep.assertions.badmodulescript)

		local requiresuccess, module = pcall(require, modulescript)
		if requiresuccess then
			if type(module) == "table" then
				if module.init and type(module.init) == "function" then
					local initsuccess, initresult = pcall(module.init)
					if initsuccess then
						--- ok
					else
						warn(scriptname(), string.format("%s.init() error:", modulescript.Name), initresult)
					end
				end
			end
		else
			warn(scriptname(), string.format("'%s' require error:", modulescript.Name), module)
		end
	end

	--- script attribute json receipt after all modules loaded
	if isserver then
		local receipt = eep.createreceipt()
		script:SetAttribute(eep.jsonflag, HttpService:JSONEncode(receipt))
	end

	--- conclude
	local elapsed = DateTime.now().UnixTimestampMillis - start
	print(scriptname(), string.format(
		"eep.main() (%s)\ntime: %dms\nactivitykey: '%s'\nmoduleset: '%s' (%d)\nsharedinstancekey: '%s'\npeer index: %d",
		isserver and "server" or "client",
		elapsed,
		eep.activity.key,
		rules.moduleset,
		#modules,
		eep.sharedinstance.key,
		eep.sharedinstance.peerindex
	))

	return elapsed
end

--- creates a minimal client-exposable receipt for running eep.main()
function eep.createreceipt()
	assert(isserver, eep.assertions.badcreatereceiptenvironment)

	return {
		peerindex = eep.sharedinstance.peerindex;
		activitykey = eep.activity.key;
		sharedinstancekey = eep.sharedinstance.key;
	}
end

---           $$\                                           $$\ $$\                       $$\                                             
---           $$ |                                          $$ |\__|                      $$ |                                            
---  $$$$$$$\ $$$$$$$\   $$$$$$\   $$$$$$\   $$$$$$\   $$$$$$$ |$$\ $$$$$$$\   $$$$$$$\ $$$$$$\    $$$$$$\  $$$$$$$\   $$$$$$$\  $$$$$$\  
--- $$  _____|$$  __$$\  \____$$\ $$  __$$\ $$  __$$\ $$  __$$ |$$ |$$  __$$\ $$  _____|\_$$  _|   \____$$\ $$  __$$\ $$  _____|$$  __$$\ 
--- \$$$$$$\  $$ |  $$ | $$$$$$$ |$$ |  \__|$$$$$$$$ |$$ /  $$ |$$ |$$ |  $$ |\$$$$$$\    $$ |     $$$$$$$ |$$ |  $$ |$$ /      $$$$$$$$ |
---  \____$$\ $$ |  $$ |$$  __$$ |$$ |      $$   ____|$$ |  $$ |$$ |$$ |  $$ | \____$$\   $$ |$$\ $$  __$$ |$$ |  $$ |$$ |      $$   ____|
--- $$$$$$$  |$$ |  $$ |\$$$$$$$ |$$ |      \$$$$$$$\ \$$$$$$$ |$$ |$$ |  $$ |$$$$$$$  |  \$$$$  |\$$$$$$$ |$$ |  $$ |\$$$$$$$\ \$$$$$$$\ 
--- \_______/ \__|  \__| \_______|\__|       \_______| \_______|\__|\__|  \__|\_______/    \____/  \_______|\__|  \__| \_______| \_______|
---                                                                                                                                       
---                                                                                                                                       
---                                                                                                                                       

--- runs sharedinstancestore heartbeat \
--- resyncs shared instance & peers
function eep.sharedinstancestoreheartbeat()
	--- shared instance memorystore
	local sharedinstancestore = eep.sharedinstance.store
	sharedinstancestore.value = MemoryStoreService:GetHashMap(sharedinstancestore.key)
	local sharedinstancehashmap = sharedinstancestore.value
	assert(sharedinstancehashmap and sharedinstancehashmap:IsA("MemoryStoreHashMap"), eep.assertions.badsharedinstancememorystore)

	--- heartbeat
	local function sharedinstancestoreheartbeat()
		local unixtimestampmillis = DateTime.now().UnixTimestampMillis

		local sharedinstancekey = eep.sharedinstance.key
		if sharedinstancekey == "" then return end

		local updateasyncsuccess, updateasyncresult: typeof(eep.createsharedinstance(nil:: any, nil::any))? = pcall(
			sharedinstancehashmap.UpdateAsync,
			sharedinstancehashmap,
			sharedinstancekey,
			function(sharedinstance: typeof(eep.createsharedinstance(nil:: any, nil::any))?): (any, number?)
				if sharedinstance then
					eep.sharedinstanceresync(sharedinstance, unixtimestampmillis)

					return sharedinstance
				else
					return nil
				end
			end,
			eep.sharedinstance.store.expiry
		)
		if updateasyncsuccess then
			
		else
			warn(scriptname(), "sharedinstancestore heartbeat updateasync error:", updateasyncresult)
		end
	end

	framerule(sharedinstancestore.heartbeat, -1, sharedinstancestoreheartbeat)
end

--- creates a shared instance
function eep.createsharedinstance(activitykey: string, peers: number)
	local value = {
		--- activity key for this sharedinstance
		activitykey = activitykey;

		--- unique identifier (guid) for this sharedinstance
		key = HttpService:GenerateGUID(false);
		--- unix timestamp, in milliseconds, of when this sharedinstance was instantiated
		timestamp = DateTime.now().UnixTimestampMillis;

		--- peerindex of peer that concluded this sharedinstance
		concludeindex = -1;
		--- unix timestamp, in milliseconds, of when this sharedinstance was concluded
		concludetimestamp = -1;

		--- peers
		peers = {  };
	}

	for i = 1, peers do
		table.insert(value.peers, {
			--- index of this peer relative to the sharedinstance
			index = i;
			--- variable read-write table for game-specific code
			value = {  };
			--- last time this peer was resynced
			timestamp = -1;

			--- userids allocated to this peer
			expectinguserids = {  };
			--- party keys associated with this peer
			--- (technically they get dissolved when teleported but exists for posterity)
			partykeys = {  };

			--- reservedserver accesscode
			accesscode = "";
			--- reservedserver privateserverid
			privateserverid = "";
		})
	end

	return value
end

--- push peer value up -> pull all key-value pairs down -> return sharedinstance for convenience
function eep.sharedinstanceresync(si: typeof(eep.createsharedinstance(...)), unixtimestampmillis: number)
	local datamodelpeerindex = eep.sharedinstance.peerindex
	local datamodelpeervalue = eep.sharedinstance.peervalue

	--- write datamodel peervalue to sharedinstance
	local datamodelpeer = si.peers[datamodelpeerindex]
	if datamodelpeer then
		datamodelpeer.timestamp = unixtimestampmillis
		datamodelpeer.value = datamodelpeervalue
	else
		warn(scriptname(), "this should not happen")
	end

	--- write all key-value pairs to sharedinstance value
	for k, v in si do
		eep.sharedinstance.value[k] = v
	end

	return si
end

--- returns index-peer pair of sharedinstance from non-datamodel-keyed privateserverid \
--- does not have safety against `peer.privateserverid == "" & privateserverid == ""` for compatibility with placeholder sharedinstances
function eep.sharedinstancefindpeer(si: typeof(eep.createsharedinstance(...)), privateserverid: string): (number?, typeof(eep.createsharedinstance(...).peers[1])?)
	for index, peer in ipairs(si.peers) do
		if peer.privateserverid == privateserverid then

			return index, peer
		end
	end

	return nil, nil
end

function eep.sharedinstanceresolve(sharedinstancekey: string): (boolean, typeof(eep.createsharedinstance(...))?)
	local sharedinstancehashmap = eep.sharedinstance.store.value
	assert(sharedinstancehashmap and sharedinstancehashmap:IsA("MemoryStoreHashMap"), eep.assertions.badsharedinstancememorystore)

	if sharedinstancekey == "" then

		return true, nil
	else

		return pcall(sharedinstancehashmap.GetAsync, sharedinstancehashmap, sharedinstancekey)
	end
end

--- attempts to conclude sharedinstance associated with the datamodel calling this function \
--- returns: \
--- `boolean` pcall updateasync \
--- `sharedinstance.concludeindex` peer index that concluded the sharedinstance
function eep.sharedinstanceconclude()
	local sharedinstancehashmap = eep.sharedinstance.store.value
	assert(sharedinstancehashmap and sharedinstancehashmap:IsA("MemoryStoreHashMap"), eep.assertions.badsharedinstancememorystore)

	local unixtimestampmillis = DateTime.now().UnixTimestampMillis
	local peerindex = eep.sharedinstance.peerindex

	local updateasyncsuccess, updateasyncresult: typeof(eep.createsharedinstance(nil:: any, nil::any))? = pcall(
		sharedinstancehashmap.UpdateAsync,
		sharedinstancehashmap,
		eep.sharedinstance.key,
		function(sharedinstance: typeof(eep.createsharedinstance(nil:: any, nil::any))?): (any, number?)
			if sharedinstance then
				eep.sharedinstanceresync(sharedinstance, unixtimestampmillis)
				
				if sharedinstance.concludeindex == -1 and sharedinstance.concludetimestamp == -1 then
					sharedinstance.concludeindex = peerindex
					sharedinstance.concludetimestamp = unixtimestampmillis
				end

				return sharedinstance
			else
				return nil
			end
		end,
		eep.sharedinstance.store.expiry
	)
	if updateasyncsuccess and updateasyncresult then
		return true, updateasyncresult.concludeindex
	else
		return false, -1
	end
end

--- reserves private servers for sharedinstance
function eep.sharedinstancereserveservers(si: typeof(eep.createsharedinstance(...)))
	for index, peer in ipairs(si.peers) do
		local accesscode, privateserverid = "", ""

		if isstudio then
			accesscode, privateserverid = eep.sharedinstance.emptyreserveserverstring, eep.sharedinstance.emptyreserveserverstring
		else
			accesscode, privateserverid = TeleportService:ReserveServerAsync(game.PlaceId)
		end

		peer.accesscode = accesscode
		peer.privateserverid = privateserverid
	end
end

--- applies datamodelhashmap setasync to all sharedinstance peers
function eep.sharedinstancesetasync(si: typeof(eep.createsharedinstance(...)))
	local datamodelhashmap = eep.datamodel.store.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	local sharedinstancehashmap = eep.sharedinstance.store.value
	assert(sharedinstancehashmap and sharedinstancehashmap:IsA("MemoryStoreHashMap"), eep.assertions.badsharedinstancememorystore)

	--- setasync peers
	for index, peer in ipairs(si.peers) do
		local datamodelkey = eep.datamodelkey(peer.privateserverid)
		local datamodelvalue = eep.createdatamodelvalue(si.activitykey, si.key)

		local setasyncsuccess, setasyncresult = pcall(datamodelhashmap.SetAsync, datamodelhashmap, datamodelkey, datamodelvalue, eep.datamodel.store.expiry)
		if setasyncsuccess then
			--- ok
			--- print(scriptname(), "setasync datamodelkey:", datamodelkey)
		else
			warn(setasyncresult)

			return false
		end
	end

	--- setasync sharedinstance
	local setasyncsuccess, setasyncresult = pcall(sharedinstancehashmap.SetAsync, sharedinstancehashmap, si.key, si, eep.sharedinstance.store.expiry)
	if setasyncsuccess then
		--- ok
		return true
	else
		warn(scriptname(), "sharedinstanceserasync error", setasyncresult)
		
		return false
	end
end

--- returns `{ [string partykey]: string reservedserveraccesscode }`
function eep.sharedinstanceresolveaccesscodemap(si: typeof(eep.createsharedinstance(...)))
	local result = {}
	for index, peer in ipairs(si.peers) do
		local accesscode = peer.accesscode
		for _, partykey in ipairs(peer.partykeys::{string}) do --- ????????
			result[partykey] = accesscode
		end
	end

	return result
end

function eep.sharedinstancecountuserids(si: typeof(eep.createsharedinstance(...)))
	local count = 0
	for _, peer in ipairs(si.peers) do
		count += #peer.expectinguserids
	end

	return count
end

---                       $$\     $$\            $$\   $$\               
---                       $$ |    \__|           \__|  $$ |              
---  $$$$$$\   $$$$$$$\ $$$$$$\   $$\ $$\    $$\ $$\ $$$$$$\   $$\   $$\ 
---  \____$$\ $$  _____|\_$$  _|  $$ |\$$\  $$  |$$ |\_$$  _|  $$ |  $$ |
---  $$$$$$$ |$$ /        $$ |    $$ | \$$\$$  / $$ |  $$ |    $$ |  $$ |
--- $$  __$$ |$$ |        $$ |$$\ $$ |  \$$$  /  $$ |  $$ |$$\ $$ |  $$ |
--- \$$$$$$$ |\$$$$$$$\   \$$$$  |$$ |   \$  /   $$ |  \$$$$  |\$$$$$$$ |
---  \_______| \_______|   \____/ \__|    \_/    \__|   \____/  \____$$ |
---                                                            $$\   $$ |
---                                                            \$$$$$$  |
---                                                             \______/ 

--- returns `eep.activity.key`
function eep.activitykey()
	return eep.activity.key
end

--- returns `eep.activity.value.rules[name]`
function eep.activityreadrule(name: string)
	return eep.activity.value.rules[name]
end

--- writes key, map pair to: \
--- `eep.activity.key = key` \
--- `eep.activity.value = value`
function eep.activitywrite(key: string, value: typeof(eep.activity.value))
	local activity = eep.activity
	activity.key = key
	activity.value = value

	return activity
end

---       $$\            $$\                                             $$\           $$\ 
---       $$ |           $$ |                                            $$ |          $$ |
---  $$$$$$$ | $$$$$$\ $$$$$$\    $$$$$$\  $$$$$$\$$$$\   $$$$$$\   $$$$$$$ | $$$$$$\  $$ |
--- $$  __$$ | \____$$\\_$$  _|   \____$$\ $$  _$$  _$$\ $$  __$$\ $$  __$$ |$$  __$$\ $$ |
--- $$ /  $$ | $$$$$$$ | $$ |     $$$$$$$ |$$ / $$ / $$ |$$ /  $$ |$$ /  $$ |$$$$$$$$ |$$ |
--- $$ |  $$ |$$  __$$ | $$ |$$\ $$  __$$ |$$ | $$ | $$ |$$ |  $$ |$$ |  $$ |$$   ____|$$ |
--- \$$$$$$$ |\$$$$$$$ | \$$$$  |\$$$$$$$ |$$ | $$ | $$ |\$$$$$$  |\$$$$$$$ |\$$$$$$$\ $$ |
---  \_______| \_______|  \____/  \_______|\__| \__| \__| \______/  \_______| \_______|\__|
---                                                                                        
---                                                                                        
---                                                                                        

--- runs datamodelstore heartbeat \
--- is never actually heartbeat-ed and only sets the memorystore for
--- eep.main() datamodelvalue pull
function eep.datamodelheartbeat()
	--- datamodelvalue memorystore
	local datamodelstore = eep.datamodel.store
	datamodelstore.value = MemoryStoreService:GetHashMap(datamodelstore.key)
	local datamodelhashmap = datamodelstore.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	--- see eep.datamodelstore comments
	--- pattern exists only for consistency
	--- 
	--- --- heartbeat
	--- local function datamodelstoreheartbeat()
	--- 	
	--- end
	--- 
	--- framerule(datamodelstore.heartbeat, -1, datamodelstoreheartbeat)
end

--- creates a datamodelvalue
function eep.createdatamodelvalue(activitykey: string, sharedinstancekey: string)
	return {
		activitykey = activitykey;
		sharedinstancekey = sharedinstancekey;
	}
end

--- returns datamodelvalue associated with the datamodel calling this function \
--- if the datamodel calling this function is a public instance, returns `true, nil`
function eep.datamodelresolve(): (boolean, typeof(eep.createdatamodelvalue(...))?)
	local datamodelhashmap = eep.datamodel.store.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	if eep.datamodel.key == "" then
		return true, nil
	else
		return pcall(datamodelhashmap.GetAsync, datamodelhashmap, eep.datamodel.key)
	end
end

--- returns matchmakingtype-suffixed string \
--- if `privateserverid == ""`, returns empty string `""`
function eep.datamodelkey(privateserverid: string)
	if privateserverid == "" then
		return ""
	else
		return privateserverid .. "_" .. tostring(game.MatchmakingType.Value)
	end
end

---                                $$\               
---                                $$ |              
---  $$$$$$\   $$$$$$\   $$$$$$\ $$$$$$\   $$\   $$\ 
--- $$  __$$\  \____$$\ $$  __$$\\_$$  _|  $$ |  $$ |
--- $$ /  $$ | $$$$$$$ |$$ |  \__| $$ |    $$ |  $$ |
--- $$ |  $$ |$$  __$$ |$$ |       $$ |$$\ $$ |  $$ |
--- $$$$$$$  |\$$$$$$$ |$$ |       \$$$$  |\$$$$$$$ |
--- $$  ____/  \_______|\__|        \____/  \____$$ |
--- $$ |                                   $$\   $$ |
--- $$ |                                   \$$$$$$  |
--- \__|                                    \______/ 

--- runs matchmakingtask heartbeat \
function eep.partyheartbeat(activitymap: { __studioactivity: string; __defaultactivity: string; [string]: typeof(eep.activity.value); })
	--- datamodelvalue memorystore
	local partystore = eep.party.store
	partystore.value = MemoryStoreService:GetSortedMap(partystore.key)
	local partysortedmap = partystore.value
	assert(partysortedmap and partysortedmap:IsA("MemoryStoreSortedMap"), eep.assertions.badpartymemorystore)

	--- heartbeat
	local function partyheartbeat()
		--- party matchmaking task
		local tasktype = partystore.tasktype

		if tasktype == "local" then
			--- resync from sortedmap
			eep.partyprestep()

			--- teleport
			eep.partyteleportstep()

			--- convert to getasyncresult
			local fakegetasyncresult = {}
			for _, party in ipairs(eep.party.value) do
				table.insert(fakegetasyncresult, {
					key = party.key;
					sortKey = party.timestamp;
					value = party;
				})
			end

			--- pool local parties, apply matchmaking
			local pool = eep.createpool(fakegetasyncresult)
			local receipt = eep.poolallocatestep(pool, activitymap)
			local partykeyaccesscodemap = eep.poolpopulatestep(receipt)
			local writeaccesscodesuccess = eep.poolwriteaccesscodestep(partykeyaccesscodemap)
			if writeaccesscodesuccess then
				--- ok
			else
				warn(scriptname(), "error updateasync-ing parties with reservedserveraccesscode")
			end

		elseif tasktype == "global" then
			--- resync from sortedmap
			eep.partyprestep()

			--- teleport
			eep.partyteleportstep()

			--- get talking stick
			local hastalkingstick = eep.talkingstickattemptclaim()

			if hastalkingstick == true then
				--- getrangeasync pull
				local getrangeasyncsuccess, getrangeasyncresult: { {
					key: string;
					sortKey: number;
					value: typeof(eep.party.value[1]);
				} }? = pcall(
					partysortedmap.GetRangeAsync,
					partysortedmap,
					Enum.SortDirection.Ascending,
					partystore.pull,
					partystore.exclusivelowerbound
				)
				if getrangeasyncsuccess and getrangeasyncresult then
					--- pool parties, apply matchmaking
					local pool = eep.createpool(getrangeasyncresult)
					local receipt = eep.poolallocatestep(pool, activitymap)
					local partykeyaccesscodemap = eep.poolpopulatestep(receipt)
					local writeaccesscodesuccess = eep.poolwriteaccesscodestep(partykeyaccesscodemap)
					if writeaccesscodesuccess then
						--- ok
					else
						warn(scriptname(), "error updateasync-ing parties with reservedserveraccesscode")
					end

				else
					warn(scriptname(), "partysortedmap getrangeasync error:", getrangeasyncresult)
				end
			else
				--- datamodel does not have the talking stick ToT
			end

		else
			--- naur
			warn(scriptname(), "unknown matchmakingtasktype:", tasktype)

			return
		end
	end
	
	framerule(partystore.heartbeat, -1, partyheartbeat)
end

--- resyncs parties from this datamodel \
--- removes if not present \
--- returns operation time
function eep.partyprestep()
	local partysortedmap = eep.party.store.value
	assert(partysortedmap and partysortedmap:IsA("MemoryStoreSortedMap"), eep.assertions.badpartymemorystore)

	local unixtimestampmillis = DateTime.now().UnixTimestampMillis

	for _, datamodelparty in ipairs(eep.party.value) do
		local key = datamodelparty.key

		local updateasyncsuccess, updateasyncresult = pcall(
			partysortedmap.UpdateAsync,
			partysortedmap,
			key,
			function(p: typeof(eep.createparty())?): (any, number?)
				if p then
					--- write from datamodel party to memorystore party
					p.userids = datamodelparty.userids
					p.invites = datamodelparty.invites
					p.activitykey = datamodelparty.activitykey
				else
					p = datamodelparty
				end

				assert(p ~= nil)

				--- update timestamp
				if p.accesscode ~= "" then
					--- was assigned activity
					p.timestamp = -1
				elseif p.activitykey == "" then
					--- not queued for anything
					p.timestamp = -1
				elseif #p.userids <= 0 then
					--- empty party
					p.timestamp = -1
				else
					if p.timestamp == -1 then
						--- queue
						p.timestamp = unixtimestampmillis
					else
						--- already queued
					end
				end

				--- write from memorystore party to datamodel party
				datamodelparty.accesscode = p.accesscode
				datamodelparty.timestamp = p.timestamp

				return p, p.timestamp
			end,
			eep.party.store.expiry
		)
		if updateasyncsuccess then
			--- ok
		else
			warn(scriptname(), "prestep updateasync error:", updateasyncresult)
		end
	end

	return DateTime.now().UnixTimestampMillis - unixtimestampmillis
end


function eep.partyteleportstep()
	for _, datamodelparty in ipairs(eep.party.value) do
		local reservedserveraccesscode = datamodelparty.accesscode
		
		if reservedserveraccesscode ~= "" then

			if isstudio then
				--- print("not teleporting (studio)")
			else
				local teleportoptions = Instance.new("TeleportOptions")
				teleportoptions.ReservedServerAccessCode = reservedserveraccesscode

				local teleportasyncsuccess, teleportasyncresult = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, eep.useridstoplayers(datamodelparty.userids), teleportoptions)
				if teleportasyncsuccess then
					--- ok
					print(scriptname(), string.format("teleporting [%s] to activity %s", table.concat(datamodelparty.userids, ", "), reservedserveraccesscode))
				else
					warn(scriptname(), string.format("partyteleportstep() error: (unable to teleport [%s])", table.concat(datamodelparty.userids, ", ")), teleportasyncresult)
				end
			end
		end
	end
end

--- creates a queued-for-activity pool \
--- `{[string activitykey]: { {key: string; userids: {number}} }}`
function eep.createpool(getrangeasyncresult: {{
	key: string;
	sortKey: number;
	value: typeof(eep.party.value[1]);
}})
	local pool = {
		--- population `{[string activitykey]: number # userids queued}`
		__pop = {};
	}

	for i, v in ipairs(getrangeasyncresult) do
		local party = v.value
		--- do not consider if empty activitykey
		local activitykey = party.activitykey
		if activitykey == "" then continue end

		--- do not consider if already has accesscode
		local accesscode = party.accesscode
		if accesscode ~= "" then continue end

		--- do not consider if timestamp is lt 0 (indicates dequeued)
		local timestamp = party.timestamp
		if timestamp == -1 then continue end

		if not pool[activitykey] then
			pool[activitykey] = table.create(eep.party.store.pull)
		end
		if not pool.__pop[activitykey] then
			pool.__pop[activitykey] = 0
		end

		table.insert(pool[activitykey], { key = party.key; userids = party.userids; })
		pool.__pop[activitykey] += #party.userids
	end

	return pool
end

--- check if party still exists \
--- preallocate userids for each activity type \
--- create sharedinstance for each successful preallocation \
--- allocate userids to sharedinstance peers \
--- updateasync relevant parties with sharedinstance peer accesscode \
--- returns `{ typeof(eep.createsharedinstance(...)) }`
function eep.poolallocatestep(pool: typeof(eep.createpool(...)), activitymap: { __studioactivity: string; __defaultactivity: string; [string]: typeof(eep.activity.value); })
	local partysortedmap = eep.party.store.value
	assert(partysortedmap and partysortedmap:IsA("MemoryStoreSortedMap"), eep.assertions.badpartymemorystore)

	--- filter allocatable based on:
	--- population of userids queued for activity
	--- whether the party queued for this activity is still queued for this activity
	--- "if the parties queued for this activity were to be assigned a sharedinstance peer, what would it look like"

	--- todo this can be a recursive operaton to flush the entire range
	--- but keeping it 1 per poolstep per activity in the meantime

	local receipt = {}

	for activitykey, entries in pool do
		if activitykey == "__pop" then continue end

		local pop = pool.__pop[activitykey] or 0
		local a = activitymap[activitykey]
		local sharedinstancepeers = a.rules.sharedinstancepeers
		local sharedinstanceuseridsperpeer = a.rules.sharedinstanceuseridsperpeer
		local required = sharedinstancepeers * sharedinstanceuseridsperpeer

		--- pulse check
		for i = #entries, 1, -1 do
			local entry = entries[i]

			local getasyncsuccess, p: typeof(eep.createparty())? = pcall(
				partysortedmap.GetAsync,
				partysortedmap,
				entry.key
			)

			local remove = false
			if getasyncsuccess and p then
				remove = p.accesscode ~= "" or --- was assigned activity
						p.activitykey == "" or --- not queued for anything
						#p.userids <= 0 or --- empty party
						p.timestamp == -1 or --- dequeued
						false
			else
				remove = true

				if not getasyncsuccess then
					warn(scriptname(), "pulse check getasync error:", p)
				end
			end

			if remove == true then
				pop -= #entry.userids

				table.remove(entries, i)
			end
		end

		if pop < required then continue end

		--- allocate
		local sharedinstance = eep.createsharedinstance(activitykey, sharedinstancepeers)
		for peerindex = 1, sharedinstancepeers do
			local userids = table.create(sharedinstanceuseridsperpeer);
			local partykeys = table.create(sharedinstanceuseridsperpeer);

			local toremove = table.create(sharedinstanceuseridsperpeer)

			for i, entry in ipairs(entries) do
				--- if userids can fit into this peer,
				--- allocate userids
				--- insert party key for later sending accesscode
				if #userids + #entry.userids <= sharedinstanceuseridsperpeer then
					table.move(entry.userids, 1, #entry.userids, #userids + 1, userids)
					table.insert(partykeys, entry.key)

					table.insert(toremove, i)

					if #userids == sharedinstanceuseridsperpeer then
						break
					end
				end
			end

			for i = #toremove, 1, -1 do
				table.remove(entries, toremove[i])
			end

			--- insert if and only if exactly enough userids were allocated
			if #userids == sharedinstanceuseridsperpeer then
				local peer = sharedinstance.peers[peerindex]
				
				table.move(userids, 1, #userids, #peer.expectinguserids + 1, peer.expectinguserids)
				table.move(partykeys, 1, #partykeys, #peer.partykeys + 1, peer.partykeys)
			end
		end

		--- insert if and only if all hypothetical peers were allocated
		if eep.sharedinstancecountuserids(sharedinstance) == required then
			table.insert(receipt, sharedinstance)
		end
	end

	return receipt
end

--- reserves servers \
--- setasync to memorystore \
--- returns { [string partykey]: string reservedserveraccesscode }
function eep.poolpopulatestep(sharedinstances: { typeof(eep.createsharedinstance(...)) })
	local result = {}

	for i, sharedinstance in ipairs(sharedinstances) do
		eep.sharedinstancereserveservers(sharedinstance)
		local setasyncsuccess = eep.sharedinstancesetasync(sharedinstance)
		if setasyncsuccess then
			local accesscodemap = eep.sharedinstanceresolveaccesscodemap(sharedinstance)

			for partykey, reservedserveraccesscode in accesscodemap do
				result[partykey] = reservedserveraccesscode
			end
		else
			break
		end
	end

	return result
end

--- partyaccesscodemap `{ [string partykey]: string reservedserveraccesscode }`
function eep.poolwriteaccesscodestep(partykeyaccesscodemap: {[string]: string})
	local success = true

	local partysortedmap = eep.party.store.value
	assert(partysortedmap and partysortedmap:IsA("MemoryStoreSortedMap"), eep.assertions.badpartymemorystore)

	for partykey, reservedserveraccesscode in partykeyaccesscodemap do
		local updateasyncsuccess, updateasyncresult = pcall(
			partysortedmap.UpdateAsync,
			partysortedmap,
			partykey,
			function(p: typeof(eep.createparty())?): (any, number?)
				if p then
					p.accesscode = reservedserveraccesscode
					
					return p
				end

				return nil
			end,
			eep.party.store.expiry
		)
		if updateasyncsuccess then
			--- ok
		else
			success = false

			warn(scriptname(), "prestep updateasync error:", updateasyncresult)
			break
		end
	end

	return success
end

--- creates a matchmakingtask talking stick
function eep.createtalkingstick()
	return {
		timestamp = DateTime.now().UnixTimestampMillis;
		jobid = game.JobId;
	}
end

--- attempts to claim the talking stick for global matchmaking \
--- returns `eep.party.store.talkingstickvalue` for convenience
function eep.talkingstickattemptclaim()
	local partystore = eep.party.store

	local datamodelhashmap = eep.datamodel.store.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	local talkingsticksuccess, talkingstickresult = pcall(
		datamodelhashmap.UpdateAsync,
		datamodelhashmap,
		partystore.talkingstickkey,
		function(t: typeof(eep.createtalkingstick())?): any
			if t == nil or t and t.jobid == game.JobId then

				return eep.createtalkingstick()
			else

				return nil
			end
		end,
		partystore.expiry
	)
	if talkingsticksuccess then
		partystore.talkingstickvalue = talkingstickresult ~= nil and talkingstickresult.jobid == game.JobId or false
	else
		partystore.talkingstickvalue = false

		warn(scriptname(), "claim talking stick error:", talkingstickresult)
	end

	return partystore.talkingstickvalue
end

--- converts userids to player instances
function eep.useridstoplayers(userids: {number})
	local result = table.create(#userids)

	for _, userid in ipairs(userids) do
		local player = Players:GetPlayerByUserId(userid)
		if player then
			table.insert(result, player)
		end
	end

	return result
end

--- creates an empty party \
--- accesscodes are userid-specific and are independent from party
function eep.createparty(): typeof(eep.party.value[1])
	return {
		key = HttpService:GenerateGUID(false);

		userids = table.create(Players.MaxPlayers);
		invites = table.create(Players.MaxPlayers);
		activitykey = "";

		timestamp = -1;
		accesscode = "";
	}
end

function eep.partyinsert(p: typeof(eep.createparty()))
	if not eep.partyfindfromkey(p.key) then
		table.insert(eep.party.value, p)
		
		return true
	end

	return false
end

--- returns index,party pair of party whose key matches key
function eep.partyfindfromkey(key: string): (number?, typeof(eep.createparty())?)
	for i, p in ipairs(eep.party.value) do
		if p.key == key then
			return i, p
		end
	end

	return nil, nil
end

--- removes any parties with no userids
function eep.partyclearemptyparties()
	for i = #eep.party.value, 1, -1 do
		local p = eep.party.value[i]
		
		if #p.userids < 1 then
			table.remove(eep.party.value, i)
		end
	end
end

--- removes all occurrences of userid in all parties
function eep.partyclear(userid: number)
	for _, p in ipairs(eep.party.value) do
		eep.partyremoveuserid(p, userid)
		eep.partyremoveinvite(p, userid)
	end
end

--- returns first userid of party
function eep.partyreadhost(p: typeof(eep.createparty()))
	return p.userids[1]
end

--- finds first occurrence of userid in parties
function eep.partyfind(userid: number): (typeof(eep.createparty())?, number?)
	for _, p in ipairs(eep.party.value) do
		local i = eep.partyfinduserid(p, userid)
		if i then
			return p, i
		end
	end

	return nil, nil
end

--- returns first occurrence of userid in party userids
function eep.partyfinduserid(p: typeof(eep.createparty()), userid: number)
	return table.find(p.userids, userid)
end

--- inserts userid into party userids, if userid is not already present \
--- returns true if userid was actually inserted
function eep.partyadduserid(p: typeof(eep.createparty()), userid: number)
	if not table.find(p.userids, userid) then
		table.insert(p.userids, userid)

		return true
	end

	return false
end

--- removes userid from party userids, if userid is present \
--- returns true if userid was actually removed
function eep.partyremoveuserid(p: typeof(eep.createparty()), userid: number)
	for i = #p.userids, 1, -1 do
		if p.userids[i] == userid then
			table.remove(p.userids, i)
		end
	end
end

--- returns first occurrence of userid in party invites
function eep.partyfindinvite(p: typeof(eep.createparty()), userid: number)
	return table.find(p.invites, userid)
end

--- inserts userid into party invites, if userid is not already present \
--- returns true if userid was actually inserted
function eep.partyaddinvite(p: typeof(eep.createparty()), userid: number)
	if not table.find(p.invites, userid) then
		table.insert(p.invites, userid)

		return true
	end

	return false
end

--- removes userid from party invites, if userid is present \
--- returns true if userid was actually removed
function eep.partyremoveinvite(p: typeof(eep.createparty()), userid: number)
	local result = false
	for i = #p.userids, 1, -1 do
		if p.userids[i] == userid then
			table.remove(p.userids, i)

			result = true
		end
	end

	return result
end

return eep