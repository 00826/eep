--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local LocalizationService = game:GetService("LocalizationService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local isserver = RunService:IsServer()
local isstudio = RunService:IsStudio()

local structureversionkey = string.format("%x", 0)

--- runs function at `step` second interval for `time` seconds \
--- exceptions: \
--- `step == -1`: function is called every heartbeat \
--- `time == -1`: bound function runs indefinitely
local function framerule(step: number, time: number, f: (dt: number, elapsed: number) -> (), immediate: boolean?): (RBXScriptConnection, thread?)
	if time == -1 then
		local start = os.clock()
		local recent = os.clock()
		if immediate ~= false then
			recent -= step or 1/60 --- doesn't matter
		end

		if step == -1 then
			return RunService.Heartbeat:Connect(function(dt)
				f(dt, os.clock() - start)
			end), nil
		else
			return RunService.Heartbeat:Connect(function()
				local now = os.clock()
				local dt = now - recent
				if dt > step then
					recent = now - (dt - step)

					f(dt, now - start)
				end
			end), nil
		end
	else
		local connection = framerule(step, -1, f, immediate)

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
		index = -1;
		value = {  } :: {
			--- ## datamodel settings
			--- what modules will run when `eep.main(...)` is called
			moduleset: string;
			--- will this datamodel attempt to claim the talking stick
			doclaimtalkingstick: boolean;
			--- will this datamodel update itself to its associated shared instance
			dosharedinstancerefresh: boolean;
			--- will this datamodel pull from postgame sorted/recent stores
			dopostgamerefresh: boolean;
			--- on conclusion, will this datamodel publish a developer-prescribed postgame value (read externally)
			publishpostgame: boolean;

			--- ## activity settings
			--- when this activity is queued, how many peers will be created
			sharedinstancepeers: number;
			--- how many players will be allocated into each shared instance peer
			sharedinstanceuseridsperpeer: number;

			--- ## game-specific key-value pairs
			[string]: any;
		};
	};
	--- datamodelstore is never updated
	--- and is a one-time shabang that that gets pulled
	--- on datamodel init
	datamodel = {
		--- memorystore
		store = {
			key = "eep_datamodels" .. structureversionkey;
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
			key = "eep_sharedinstances" .. structureversionkey;
			value = nil :: MemoryStoreHashMap?;
			expiry = 1 * (60);
			heartbeat = 2;
		};

		peerindex = -1;
		peervalue = {};

		key = "";
		value = {} :: {
			--- activity key for this sharedinstance
			activityindex: number;

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
					value: { [any]: any };
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
	--- talkingstick
	talkingstick = {
		store = {
			key = "eep_talkingstick" .. structureversionkey;
			value = nil :: MemoryStoreHashMap?;
			expiry = 12 + 1;
			heartbeat = 6;

			topic = "talkingstick" .. structureversionkey;
			subscribeasyncconnection = nil :: RBXScriptConnection?;

			--- read externally for sending fixed-rate messages to talkingstick instances
			messageheartbeat = 2;
		};
		baton = {
			key = "baton" .. structureversionkey;
			value = nil :: any;
			expiry = 60;
		};

		--- key .. separator .. regionindex
		separator = "_";
		hastalkingstick = false;
	};
	--- private servers
	privateservers = {
		store = {
			key = "eep_privateservers" .. structureversionkey;
			value = nil :: MemoryStoreHashMap?;
			--- 3600 = 1h
			--- 86400 = 1d
			expiry = 6 * 3600;
			heartbeat = 0;
		};

		--- return value of getasync(game.privateserverid)
		datamodel = {
			key = "";
			value = nil :: any;
			accesscode = "";
			privateserverid = "";
			roles = {};
		};

		--- {[string stringuserid]: {string datamodelkeyinvite}}
		stringuseridinvites = {}::{[string]: {string}};

		keycache = {}::{[string]: any};
		privateserveridcache = {}::{[string]: any};
	};
	--- browser
	browser = {
		store = {
			key = "eep_browser" .. structureversionkey;
			value = nil :: MemoryStoreHashMap?;
			expiry = 2 + 16;
			heartbeat = 8;

			--- handled externally
			data = nil :: any;
		};
		--- key .. separator .. regionindex
		separator = "_";
		--- continent codes to pull regions from, written externally. separate from continentcodes as regions such as AF/AN don't exist
		pullrange = {} :: {string};

		--- raw pull value from eep.browserpull()
		--- `{[string continentcode]: any}`
		cache = {} :: { [string]: any };
		--- `{[number region index] = {externally-written data}}`
		runtime = {} :: {{any}};

		--- if regionindex is 0, how long until a retry is attempted
		zeroindexlastretry = 0;
		zeroindexretrycooldownms = 60000;
		--- number describing index of this server's region in the continentcode table
		regionindex = 0;
		continentcodes = {
			"NA"; --- north america
			"SA"; --- south america
			"EU"; --- europe
			-- "AF"; --- africa
			"AS"; --- asia
			"OC"; --- oceania
			--- "AN"; --- antarctica
			"??"; --- unknown
		};
		countryisotocontinentcode = {
			AB = "AS";
			AD = "EU";
			AE = "AS";
			AF = "AS";
			AG = "NA";
			AI = "NA";
			AL = "EU";
			AM = "AS";
			AO = "AF";
			AR = "SA";
			AS = "OC";
			AT = "EU";
			AU = "OC";
			AW = "NA";
			AX = "EU";
			AZ = "AS";
			BA = "EU";
			BB = "NA";
			BD = "AS";
			BE = "EU";
			BF = "AF";
			BG = "EU";
			BH = "AS";
			BI = "AF";
			BJ = "AF";
			BL = "NA";
			BM = "NA";
			BN = "AS";
			BO = "SA";
			BQ = "NA";
			BR = "SA";
			BS = "NA";
			BT = "AS";
			BV = "AN";
			BW = "AF";
			BY = "EU";
			BZ = "NA";
			CA = "NA";
			CC = "AS";
			CD = "AF";
			CF = "AF";
			CG = "AF";
			CH = "EU";
			CI = "AF";
			CK = "OC";
			CL = "SA";
			CM = "AF";
			CN = "AS";
			CO = "SA";
			CR = "NA";
			CU = "NA";
			CV = "AF";
			CW = "NA";
			CX = "AS";
			CY = "AS";
			CZ = "EU";
			DE = "EU";
			DJ = "AF";
			DK = "EU";
			DM = "NA";
			DO = "NA";
			DZ = "AF";
			EC = "SA";
			EE = "EU";
			EG = "AF";
			ER = "AF";
			ES = "EU";
			ET = "AF";
			FI = "EU";
			FJ = "OC";
			FK = "SA";
			FM = "OC";
			FO = "EU";
			FR = "EU";
			GA = "AF";
			GB = "EU";
			GD = "NA";
			GE = "AS";
			GF = "SA";
			GG = "EU";
			GH = "AF";
			GI = "EU";
			GL = "NA";
			GM = "AF";
			GN = "AF";
			GP = "NA";
			GQ = "AF";
			GR = "EU";
			GS = "SA";
			GT = "NA";
			GU = "OC";
			GW = "AF";
			GY = "SA";
			HK = "AS";
			HM = "AN";
			HN = "NA";
			HR = "EU";
			HT = "NA";
			HU = "EU";
			ID = "AS";
			IE = "EU";
			IL = "AS";
			IM = "EU";
			IN = "AS";
			IO = "AS";
			IQ = "AS";
			IR = "AS";
			IS = "EU";
			IT = "EU";
			JE = "EU";
			JM = "NA";
			JO = "AS";
			JP = "AS";
			KE = "AF";
			KG = "AS";
			KH = "AS";
			KI = "OC";
			KM = "AF";
			KN = "NA";
			KP = "AS";
			KR = "AS";
			KW = "AS";
			KY = "NA";
			KZ = "AS";
			LA = "AS";
			LB = "AS";
			LC = "NA";
			LI = "EU";
			LK = "AS";
			LR = "AF";
			LS = "AF";
			LT = "EU";
			LU = "EU";
			LV = "EU";
			LY = "AF";
			MA = "AF";
			MC = "EU";
			MD = "EU";
			ME = "EU";
			MF = "NA";
			MG = "AF";
			MH = "OC";
			MK = "EU";
			ML = "AF";
			MM = "AS";
			MN = "AS";
			MO = "AS";
			MP = "OC";
			MQ = "NA";
			MR = "AF";
			MS = "NA";
			MT = "EU";
			MU = "AF";
			MV = "AS";
			MW = "AF";
			MX = "NA";
			MY = "AS";
			MZ = "AF";
			NA = "AF";
			NC = "OC";
			NE = "AF";
			NF = "OC";
			NG = "AF";
			NI = "NA";
			NL = "EU";
			NO = "EU";
			NP = "AS";
			NR = "OC";
			NU = "OC";
			NZ = "OC";
			OM = "AS";
			OS = "AS";
			PA = "NA";
			PE = "SA";
			PF = "OC";
			PG = "OC";
			PH = "AS";
			PK = "AS";
			PL = "EU";
			PM = "NA";
			PR = "NA";
			PS = "AS";
			PT = "EU";
			PW = "OC";
			PY = "SA";
			QA = "AS";
			RE = "AF";
			RO = "EU";
			RS = "EU";
			RU = "EU";
			RW = "AF";
			SA = "AS";
			SB = "OC";
			SC = "AF";
			SD = "AF";
			SE = "EU";
			SG = "AS";
			SH = "AF";
			SI = "EU";
			SJ = "EU";
			SK = "EU";
			SL = "AF";
			SM = "EU";
			SN = "AF";
			SO = "AF";
			SR = "SA";
			SS = "AF";
			ST = "AF";
			SV = "NA";
			SY = "AS";
			SZ = "AF";
			TC = "NA";
			TD = "AF";
			TG = "AF";
			TH = "AS";
			TJ = "AS";
			TK = "OC";
			TM = "AS";
			TN = "AF";
			TO = "OC";
			TP = "AS";
			TR = "AS";
			TT = "NA";
			TV = "OC";
			TW = "AS";
			TZ = "AF";
			UA = "EU";
			UG = "AF";
			US = "NA";
			UY = "SA";
			UZ = "AS";
			VC = "NA";
			VE = "SA";
			VG = "NA";
			VI = "NA";
			VN = "AS";
			VU = "OC";
			WF = "OC";
			WS = "OC";
			XK = "EU";
			YE = "AS";
			YT = "AF";
			ZA = "AF";
			ZM = "AF";
			ZW = "AF";
		}::{[string]: string};
	};

	--- global leaderboards
	leaderboards = {
		--- pseudo-ordereddatastore
		sortedstore = {
			key = "eep_sortedleaderboards";
			value = nil :: DataStore?;
			heartbeat = 120;

			maxvalues = 2^8-1;
			pull = 100;

			timestampid = "";
		};
		queue = {} :: {
			{ timestampid: string; scope: string; key: any; value: any; sortvalue: number; }
		};

		--- { [string scope]: { { key: any; value: any; sortvalue: number } } }
		value = {} :: {
			[string]: {
				{
					key: any;
					value: any;
					sortvalue: number;
				}
			}
		}
	};

	--- postgame
	postgame = {
		--- pseudo-ordereddatastore
		sortedstore = {
			key = "eep_sortedpostgame";
			value = nil :: DataStore?;
			heartbeat = 120;

			maxvalues = 2^8-1;
			pull = 100;
		};
		--- recent games
		recentstore = {
			key = "eep_recentpostgame" .. structureversionkey;
			value = nil :: MemoryStoreHashMap?;
			heartbeat = 0;
			expiry = 48*60*60;
		};

		--- {string} of scopes that are getasync-ed \
		--- intended to be set in runtime and populated by activity/time period-unique strings
		scopes = {} :: {string};
		--- cache of all scoped postgame values
		value = {} :: {
			[string]: {
				{
					key: string;
					value: any;
					sortvalue: number;
					timestamp: number;
				}
			}
		};
	};

	assertions = {
		nostudioactivity = "activitymap must have a non-nil '__studioactivity' key-value pair";
		nodefaultactivity = "activitymap must have a non-nil '__defaultactivity' key-value pair";
		datamodelvalueresolveerror = "error resolving datamodelvalue, will use activitymap __default activity";
		baddatamodelmemorystore = "datamodel memorystore is nil or not a memorystorehashmap";
		badsharedinstancememorystore = "sharedinstance memorystore is nil or not a memorystorehashmap";
		badleaderboardsortedstore = "leaderboard sorted datastore is nil or not a datastore";
		badpostgamesortedstore = "postgame sorted datastore is nil or not a datastore";
		badpostgamerecentstore = "postgame recent memorystore is nil or not a memorystorehashmap";
		badprivateservermemorystore = "private server memorystore is nil or not a memorystorehashmap";
		badbrowsermemorystore = "browser memorystore is nil or not a memorystorehashmap";
		badbrowserdatapacket = "browser data packet is not nil or a table";
		browserunknownpullcontinentcode = "eep.browserpull() unknown continent code";
		badbrowserdatapacketkey = "browser data packet key is nil or not a string";
		badcreatereceiptenvironment = "eep.createreceipt() can only be called on server";
		badreceipt = "receipt is not a string";
		badactivityrules = "activity rules are nil or not a table";
		badactivitymoduleset = "activity moduleset (%s) is nil or not a table";
		badmodulescript = "modulescript in moduleset is not a modulescript";
	}::{[string]: string};

	receiptflag = "eep_receipt";
	receiptstring = "";
}

export type activitymap = { typeof(eep.activity.value) & {studioactivity: boolean, defaultactivity: boolean} & {[string]: any} }

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
	activitymap: activitymap,
	modulesets: { [string]: { ModuleScript }; },

	loadingscreen: ScreenGui?,
	loadingscreenprog: (string, number) -> ()?,
	loadingscreendestroy: () -> ()?
)
	local start = DateTime.now().UnixTimestampMillis

	--- resolve studio/default activities
	local studioactivityindex = 0
	local defaultactivityindex = 0

	for index, activitydata in ipairs(activitymap) do
		if activitydata.studioactivity == true then
			studioactivityindex = index
		end
		if activitydata.defaultactivity == true then
			defaultactivityindex = index
		end
	end

	--- guarantee existence
	assert(activitymap[studioactivityindex], eep.assertions.nostudioactivity)
	assert(activitymap[defaultactivityindex], eep.assertions.nodefaultactivity)

	if isserver then
		--- populate browser regions with tables
		for i, _ in ipairs(eep.browser.continentcodes) do
			eep.browser.runtime[i] = table.create(200)::{buffer}
		end
		--- bindtoclose removeasyncs
		--- print(scriptname(), "bindtoclose", os.clock())
		game:BindToClose(function(closereason: Enum.CloseReason)
			local datamodelkey = eep.datamodelkey(game.PrivateServerId)

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

			--- emit msg to remove server
			if eep.readkey("publishbrowserentry") == true then
				eep.browserclearlisting()
			end
		end)

		--- print(scriptname(), "resolving datamodelkey", os.clock())
		--- write datamodel key
		eep.datamodel.key = eep.datamodelkey(game.PrivateServerId)

		--- print(scriptname(), "starting heartbeats", os.clock())
		--- start all heartbeats (also inits their associated memorystores)
		eep.sharedinstancestoreheartbeat()
		eep.datamodelheartbeat()
		eep.talkingstickheartbeat()
		eep.privateserverheartbeat()
		eep.browserheartbeat()
		eep.leaderboardheartbeat()
		eep.postgameheartbeat()

		--- print(scriptname(), "resolving sharedinstance", os.clock())
		--- placeholder
		if eep.datamodel.key == "~" then
			local activityindex = defaultactivityindex
			if isstudio then
				activityindex = studioactivityindex
			end

			local placeholdersharedinstance = eep.createsharedinstance(activityindex, 1)
			eep.sharedinstancesetasync(placeholdersharedinstance)

			local datamodelhashmap = eep.datamodel.store.value
			if datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap") then
				datamodelhashmap:SetAsync(
					eep.datamodel.key,
					eep.createdatamodelvalue(activityindex, placeholdersharedinstance.key),
					eep.datamodel.store.expiry
				)
			end
			
			--- print(scriptname(), "using placeholder sharedinstance:", placeholdersharedinstance)
		end

		--- keys
		local activityindex = defaultactivityindex
		local sharedinstancekey = ""

		--- print(scriptname(), "resolving datamodel", os.clock())
		--- resolve datamodel value, write to this table
		local datamodelsuccess, datamodelvalue = eep.datamodelresolve()

		if datamodelsuccess and datamodelvalue then
			activityindex = datamodelvalue.activityindex
			sharedinstancekey = datamodelvalue.sharedinstancekey

		elseif isstudio then
			activityindex = studioactivityindex
			sharedinstancekey = ""

		elseif game.PrivateServerId == "" then
			activityindex = defaultactivityindex
			sharedinstancekey = ""

		else
			warn(scriptname(), "eep.datamodelresolve() error", datamodelvalue, "default activity will be used")

			activityindex = defaultactivityindex
			sharedinstancekey = ""

		end

		--- print(scriptname(), "writing activity", os.clock())
		eep.activitywrite(activityindex, activitymap[activityindex])

		--- print(scriptname(), "resolving sharedinstance", os.clock())
		--- resolve shared instance
		local sharedinstance = nil

		local sharedinstancesuccess, sharedinstancevalue = eep.sharedinstanceresolve(sharedinstancekey)
		if sharedinstancesuccess and sharedinstancevalue then
			sharedinstance = sharedinstancevalue
		else
			if not sharedinstancesuccess then
				warn(scriptname(), "sharedinstanceresolve() error:", sharedinstancevalue)
			end
		end

		if sharedinstance then
			local index, _ = eep.sharedinstancefindpeer(sharedinstance, game.PrivateServerId)
			
			--- reassign sharedinstancekey from shared instance for extra safety
			sharedinstancekey = sharedinstance.key
			eep.sharedinstance.key = sharedinstancekey
			eep.sharedinstance.peerindex = index or -1
			
			eep.sharedinstanceresync(sharedinstance, sharedinstance.timestamp)
		end

		--- print(scriptname(), "resolving server region", os.clock())
		--- resolve server region
		local regionindex = eep.readserverregion()
		eep.browser.regionindex = regionindex
		
		--- print(scriptname(), "done", os.clock())
	else
		if loadingscreenprog then
			pcall(loadingscreenprog, "waiting for server...", 0)
		end

		--- wait for receipt to be set
		local r = script:GetAttribute(eep.receiptflag)
		if type(r) ~= "string" then
			repeat
				task.wait()
				r = script:GetAttribute(eep.receiptflag)
			until type(r) == "string"
		end
		assert(type(r) == "string", eep.assertions.badreceipt)
		eep.receiptstring = r

		local receipt = eep.receiptread(r)
		
		--- write activityindex, sharedinstance key, sharedinstance peer index
		local activityindex = receipt.activityindex
		eep.activitywrite(activityindex, activitymap[activityindex])
		
		eep.sharedinstance.key = receipt.sharedinstancekey
		eep.sharedinstance.peerindex = receipt.peerindex
		eep.privateservers.datamodel.key = receipt.privateserverdatamodelkey
		
		eep.browser.regionindex = receipt.regionindex
		
		if loadingscreenprog then
			pcall(loadingscreenprog, string.format("loading activity '%d'", activityindex), 0)
		end
	end

	--- one-time ordered require
	local activity = eep.activity
	local moduleset = activity.value.moduleset
	assert(moduleset, string.format(eep.assertions.badactivitymoduleset, tostring(activity.value)))
	local modules = modulesets[moduleset]
	assert(modules, string.format(eep.assertions.badactivitymoduleset, tostring(activity.value)))

	--- one time ordered require
	for i, modulescript in ipairs(modules) do
		assert(modulescript:IsA("ModuleScript"), eep.assertions.badmodulescript)
		
		if loadingscreenprog then
			pcall(loadingscreenprog, string.format(
				"loading '%s' (%d/%d)",
				modulescript.Name,
				i,
				#modules
			), i / #modules)
		end

		local requiresuccess, module = pcall(require, modulescript)
		if requiresuccess then
			if type(module) == "table" then
				if type(module.init) == "function" then
					local initsuccess, initresult = pcall(module.init::any)
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

	--- script attribute receipt after all modules loaded
	if isserver then
		local r = eep.createreceipt()
		--- assert(string.len(r) <= 50, "string exceeds 50-character workspace.NextGenerationReplication attribute limit")
		
		script:SetAttribute(eep.receiptflag, r)
		eep.receiptstring = r
	end

	--- conclude
	local elapsed = DateTime.now().UnixTimestampMillis - start
	print(scriptname(), string.format(
		"eep.main() (%s)\n> time: %dms\n> moduleset: '%s' (%d)\n> ps datamodelkey: %s\n> receipt: %s\n> sharedinstance:",
		isserver and "server" or "client",
		elapsed,
		moduleset,
		#modules,
		eep.privateservers.datamodel.key,
		eep.createreceipt()
	), eep.sharedinstance.value)
	
	--- remove loading screen
	if loadingscreendestroy then
		pcall(task.spawn, loadingscreendestroy)
	end

	return elapsed
end

--- creates a minimal client-exposable receipt for running eep.main()
function eep.createreceipt()
	return string.format(
		"%d!%d!%d!%s!%s!%s",
		eep.activity.index,
		eep.sharedinstance.peerindex,
		eep.browser.regionindex,
		structureversionkey,
		eep.privateservers.datamodel.key or "",
		eep.sharedinstance.key
	)
end

--- returns table representation of `eep.createreceipt()`
function eep.receiptread(r: string)
	local split = string.split(r, "!")

	return {
		activityindex = tonumber(split[1])::number;
		peerindex = tonumber(split[2])::number;
		regionindex = tonumber(split[3])::number;
		structureversionkey = split[4];
		privateserverdatamodelkey = split[5];
		sharedinstancekey = split[6];
	}
end

--- shorthand return `RunService:IsServer() == true` and `RunService:IsStudio() == false`
function eep.readcanenvironmentteleport()
	return (isserver == true) and (isstudio == false)
end

--- teleports players to a server given its reserved-server `accesscode`
function eep.teleporttoserverwithaccesscode(players: {Player}, accesscode: string)
	assert(isserver, string.format("%s cannot teleport if calling environment is not server", scriptname()))
	assert(isstudio == false, string.format("%s cannot teleport if calling environment is in studio", scriptname()))

	local teleportoptions = Instance.new("TeleportOptions")
	teleportoptions.ReservedServerAccessCode = accesscode
	
	return pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, players, teleportoptions)
end

--- teleports players to a server given its `jobid`
function eep.teleporttoserverwithjobid(players: {Player}, jobid: string)
	assert(isserver, string.format("%s cannot teleport if calling environment is not server", scriptname()))
	assert(isstudio == false, string.format("%s cannot teleport if calling environment is in studio", scriptname()))

	local teleportoptions = Instance.new("TeleportOptions")
	teleportoptions.ServerInstanceId = jobid
	
	return pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, players, teleportoptions)
end

--- teleports players to a non-reserved `game.PlaceId`
function eep.teleporttoserver(players: {Player})
	assert(isserver, string.format("%s cannot teleport if calling environment is not server", scriptname()))
	assert(isstudio == false, string.format("%s cannot teleport if calling environment is in studio", scriptname()))

	return pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, players, nil)
end

--- returns region index (continent code) of `player`'s geolocation
function eep.readplayerregion(player: Player)
	local countrycode = LocalizationService:GetCountryRegionForPlayerAsync(player)
	local continentcode = eep.browser.countryisotocontinentcode[countrycode]

	return table.find(eep.browser.continentcodes, continentcode) or #eep.browser.continentcodes
end

function eep.createuseridconcat(userids: {number}, now: number)
	local ti = buffer.create(8 + (8 * #userids))
	buffer.writef64(ti, 0, now)
	for i, userid in ipairs(userids) do
		buffer.writef64(ti, i * 8, userid)
	end

	return ti
end

function eep.unpackuseridconcat(concat: buffer)
	local timestamp = buffer.readf64(concat, 0)
	local len = (buffer.len(concat) // 8) - 1
	local result = table.create(len)::{number}

	for i = 1, len do
		table.insert(result, buffer.readf64(concat, i * 8))
	end

	return timestamp, result
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

	if sharedinstancehashmap and sharedinstancehashmap:IsA("MemoryStoreHashMap") then
		--- heartbeat
		local function sharedinstancestoreheartbeat()
			if eep.readkey("dosharedinstancerefresh") ~= true then return end

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
	else
		warn(scriptname(), eep.assertions.badsharedinstancememorystore)
	end
end

--- creates a shared instance
function eep.createsharedinstance(activityindex: number, peers: number)
	local value = {
		--- activity key for this sharedinstance
		activityindex = activityindex;

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
			value = {  } :: {[any]: any};
			--- last time this peer was resynced
			timestamp = -1;

			--- userids allocated to this peer
			expectinguserids = {  } :: {number};
			--- party keys associated with this peer
			--- (technically they get dissolved when teleported but exists for posterity)
			partykeys = {  } :: {string};

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
	local datamodelsharedinstancevalue = eep.sharedinstance.value
	for k, v in pairs(si::any) do
		(datamodelsharedinstancevalue::any)[k] = v
	end

	return si
end

--- returns index-peer pair of sharedinstance from non-datamodel-keyed privateserverid \
--- does not have safety against `peer.privateserverid == "" & privateserverid == ""` for compatibility with placeholder sharedinstances
function eep.sharedinstancefindpeer(si: typeof(eep.createsharedinstance(...)), privateserverid: string): (number?, typeof(eep.createsharedinstance(...).peers[1])?)
	for index, peer in ipairs(si.peers or {}) do
		if peer.privateserverid == privateserverid then

			return index, peer
		end
	end

	return nil, nil
end

--- returns a filtered peer instance with only the following key-value pairs present: \
--- `number index` \
--- `{[any]: any} value` \
--- `number timestamp` datetime unixtimestampmillis
function eep.createfilteredpeer(p: typeof(eep.createsharedinstance(...).peers[1]))
	return {
		--- index of this peer relative to the sharedinstance
		index = p.index;
		--- variable read-write table for game-specific code
		value = p.value;
		--- last time this peer was resynced
		timestamp = p.timestamp;
	}
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

		if accesscode and privateserverid then
			peer.accesscode = accesscode
			peer.privateserverid = privateserverid
		else
			warn(scriptname(), "accesscode and/or privateserverid are nil")
		end
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
		local datamodelvalue = eep.createdatamodelvalue(si.activityindex, si.key)

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

--- returns `eep.activity.index`
function eep.activityindex()
	return eep.activity.index
end

--- returns `eep.activity.value[key]`
function eep.readkey(key: string): any?
	return eep.activity.value[key] or nil
end

--- writes key, map pair to: \
--- `eep.activity.index = key` \
--- `eep.activity.value = value`
function eep.activitywrite(index: number, value: index<activitymap, number>)
	local activity = eep.activity
	activity.index = index
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

	if datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap") then
		--- see eep.datamodelstore comments
		--- pattern exists only for consistency
		--- 
		--- --- heartbeat
		--- local function datamodelstoreheartbeat()
		--- 	
		--- end
		--- 
		--- framerule(datamodelstore.heartbeat, -1, datamodelstoreheartbeat)
	else
		warn(scriptname(), eep.assertions.baddatamodelmemorystore)
	end
end

--- creates a datamodelvalue
function eep.createdatamodelvalue(activityindex: number, sharedinstancekey: string)
	return {
		activityindex = activityindex;
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
--- if `privateserverid == ""`, returns string `"~"`
function eep.datamodelkey(privateserverid: string)
	if privateserverid == "" then
		return "~"
	else
		return privateserverid .. "_" .. tostring(game.MatchmakingType.Value)
	end
end

---   $$\               $$\ $$\       $$\                                 $$\     $$\           $$\       
---   $$ |              $$ |$$ |      \__|                                $$ |    \__|          $$ |      
--- $$$$$$\    $$$$$$\  $$ |$$ |  $$\ $$\ $$$$$$$\   $$$$$$\   $$$$$$$\ $$$$$$\   $$\  $$$$$$$\ $$ |  $$\ 
--- \_$$  _|   \____$$\ $$ |$$ | $$  |$$ |$$  __$$\ $$  __$$\ $$  _____|\_$$  _|  $$ |$$  _____|$$ | $$  |
---   $$ |     $$$$$$$ |$$ |$$$$$$  / $$ |$$ |  $$ |$$ /  $$ |\$$$$$$\    $$ |    $$ |$$ /      $$$$$$  / 
---   $$ |$$\ $$  __$$ |$$ |$$  _$$<  $$ |$$ |  $$ |$$ |  $$ | \____$$\   $$ |$$\ $$ |$$ |      $$  _$$<  
---   \$$$$  |\$$$$$$$ |$$ |$$ | \$$\ $$ |$$ |  $$ |\$$$$$$$ |$$$$$$$  |  \$$$$  |$$ |\$$$$$$$\ $$ | \$$\ 
---    \____/  \_______|\__|\__|  \__|\__|\__|  \__| \____$$ |\_______/    \____/ \__| \_______|\__|  \__|
---                                                 $$\   $$ |                                            
---                                                 \$$$$$$  |                                            
---                                                  \______/                                             

function eep.talkingstickheartbeat()
	local talkingstickstore = eep.talkingstick.store

	local function talkingstickheartbeat()
		if eep.readkey("doclaimtalkingstick") == true then
			local hastalkingstick, talkingstickjobid = eep.talkingstickattemptclaim()
			if hastalkingstick then
				--- claimed
			else
				--- do nothing
			end
			eep.talkingsticksubscribe(hastalkingstick)

			--- print("claim talkingstick result:", hastalkingstick)

			eep.talkingstickclaimed(hastalkingstick, talkingstickjobid)
		end
	end

	framerule(talkingstickstore.heartbeat, -1, talkingstickheartbeat)
end

function eep.talkingsticksubscribe(state: boolean)
	local talkingstickstore = eep.talkingstick.store
	local regiontopic = talkingstickstore.topic .. eep.talkingstick.separator .. eep.browser.regionindex

	if state == true then
		if talkingstickstore.subscribeasyncconnection == nil then
			local subscribeasyncsuccess, subscribeasyncresult = pcall(
				MessagingService.SubscribeAsync,
				MessagingService,
				regiontopic,
				function(t: { Data: any; Sent: number })
					eep.talkingstickmessagereceived(t.Data, t.Sent * 1000)
				end
			)
			if subscribeasyncsuccess then
				--- ok
				talkingstickstore.subscribeasyncconnection = subscribeasyncresult
			else
				warn(scriptname(), "talkingstick subscribeasync error:", subscribeasyncresult)
			end
		end
	else
		if talkingstickstore.subscribeasyncconnection then
			talkingstickstore.subscribeasyncconnection:Disconnect()
			talkingstickstore.subscribeasyncconnection = nil
		end
	end
end

function eep.talkingsticksendmessage(data: any, regionindex: number?)
	local talkingstickstore = eep.talkingstick.store
	local regiontopic = talkingstickstore.topic .. eep.talkingstick.separator .. (regionindex or eep.browser.regionindex)

	return pcall(
		MessagingService.PublishAsync,
		MessagingService,
		regiontopic,
		data
	)
end

--- to be overwritten externally \
--- fired when this server (if it has the talking stick) receives a message
function eep.talkingstickmessagereceived(data: any, unixtimestampmillis: number)
	
end

function eep.talkingstickupdatebaton(transform: (value: any) -> (any), regionindex: number?)
	local talkingstickbaton = eep.talkingstick.baton

	local datamodelhashmap = eep.datamodel.store.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	return pcall(
		datamodelhashmap.UpdateAsync,
		datamodelhashmap,
		talkingstickbaton.key .. eep.talkingstick.separator .. (regionindex or eep.browser.regionindex),
		transform,
		talkingstickbaton.expiry
	)
end

function eep.talkingstickreadbaton()
	local talkingstickbaton = eep.talkingstick.baton

	local datamodelhashmap = eep.datamodel.store.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	return pcall(
		datamodelhashmap.GetAsync,
		datamodelhashmap,
		talkingstickbaton.key .. eep.talkingstick.separator .. eep.browser.regionindex
	)
end

function eep.talkingstickpushbaton()
	local talkingstickbaton = eep.talkingstick.baton

	local datamodelhashmap = eep.datamodel.store.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	return pcall(
		datamodelhashmap.SetAsync,
		datamodelhashmap,
		talkingstickbaton.key .. eep.talkingstick.separator .. eep.browser.regionindex,
		talkingstickbaton.value,
		talkingstickbaton.expiry
	)
end

--- to be overwritten externally \
--- fires regardless if the talking stick is already claimed by this datamodel
function eep.talkingstickclaimed(hastalkingstick: boolean, talkingstickjobid: string?)

end

--- creates a talking stick unique to this server
function eep.createtalkingstick()
	return {
		timestamp = DateTime.now().UnixTimestampMillis;
		jobid = game.JobId;
	}
end

--- attempts to claim the talking stick for regionindex-specific matchmaking \
--- returns `eep.talkingstick.hastalkingstick` for convenience
function eep.talkingstickattemptclaim()
	local talkingstickstore = eep.talkingstick.store

	local datamodelhashmap = eep.datamodel.store.value
	assert(datamodelhashmap and datamodelhashmap:IsA("MemoryStoreHashMap"), eep.assertions.baddatamodelmemorystore)

	local talkingstickjobid: string? = nil
	local talkingsticksuccess, talkingstickresult = pcall(
		datamodelhashmap.UpdateAsync,
		datamodelhashmap,
		talkingstickstore.key .. eep.talkingstick.separator .. eep.browser.regionindex,
		function(t: typeof(eep.createtalkingstick())?): any
			if type(t) == "table" then
				talkingstickjobid = t.jobid
			end

			if t == nil or t and t.jobid == game.JobId then
				t = eep.createtalkingstick()
				talkingstickjobid = t.jobid

				return t

			else
				return nil

			end
		end,
		talkingstickstore.expiry
	)
	if talkingsticksuccess then
		eep.talkingstick.hastalkingstick = talkingstickresult ~= nil and talkingstickresult.jobid == game.JobId or false
	else
		eep.talkingstick.hastalkingstick = false

		warn(scriptname(), "claim talking stick error:", talkingstickresult)
	end

	return eep.talkingstick.hastalkingstick, talkingstickjobid
end

---  $$$$$$\       $$$$$$$\  $$$$$$\   $$$$$$\  $$\    $$\  $$$$$$\   $$$$$$\   $$$$$$$\ 
--- $$  __$$\     $$  _____|$$  __$$\ $$  __$$\ \$$\  $$  |$$  __$$\ $$  __$$\ $$  _____|
--- $$ /  $$ |    \$$$$$$\  $$$$$$$$ |$$ |  \__| \$$\$$  / $$$$$$$$ |$$ |  \__|\$$$$$$\  
--- $$ |  $$ |     \____$$\ $$   ____|$$ |        \$$$  /  $$   ____|$$ |       \____$$\ 
--- $$$$$$$  |$$\ $$$$$$$  |\$$$$$$$\ $$ |         \$  /   \$$$$$$$\ $$ |      $$$$$$$  |
--- $$  ____/ \__|\_______/  \_______|\__|          \_/     \_______|\__|      \_______/ 
--- $$ |                                                                                 
--- $$ |                                                                                 
--- \__|                                                                                 

--- runs browser heartbeat
function eep.privateserverheartbeat()
	--- shared instance memorystore
	local pserverstore = eep.privateservers.store
	pserverstore.value = MemoryStoreService:GetHashMap(pserverstore.key)

	local privateserverid = game.PrivateServerId
	if privateserverid ~= "" then
		--- print(string.format("HELLO MY NAME IS '%s'", privateserverid))
		local pserverhashmap = pserverstore.value
		assert(pserverhashmap and pserverhashmap:IsA("MemoryStoreHashMap"), eep.assertions.badprivateservermemorystore)

		local keygetasyncsuccess, keygetasyncresult: typeof(eep.createprivateserverprivateserveridvalue()) = pcall(
			pserverhashmap.GetAsync,
			pserverhashmap,
			privateserverid
		)
		if keygetasyncsuccess then
			if type(keygetasyncresult) == "table" then
				local privateserverdatamodel = eep.privateservers.datamodel

				print(scriptname(), "pserverhashmap keygetasync success:", keygetasyncresult)
				for k, v in keygetasyncresult::any do
					privateserverdatamodel[k] = v
				end
			else
				warn(scriptname(), string.format("pserverhashmap keygetasync expected table, got %s", type(keygetasyncresult)))
			end
		else
			warn(scriptname(), "eep.privateserverheartbeat keygetasync error", keygetasyncresult)
		end
	end
end

--- `key` holds a pointer to another key `privateserverid` to guarantee exclusivity for that specific key \
--- `privateserverid` holds variant information \
--- \
--- "Access codes remain valid indefinitely, meaning reserved servers can still be joined if no game server is running (in this case a new server will be started)."
--- "The DataModel.PrivateServerId is constant across all server instances associated with the server access code, the DataModel.JobId is not."
function eep.privateserverpublish(key: string, value: any)
	local pserverstore = eep.privateservers.store

	local pserverhashmap = pserverstore.value
	assert(pserverhashmap and pserverhashmap:IsA("MemoryStoreHashMap"), eep.assertions.badprivateservermemorystore)

	if (eep.privateservers.datamodel.key == key) and (key ~= "") then
		eep.privateservers.datamodel.value = value
	end

	local keyupdateasyncsuccess, keyupdateasyncresult = pcall(
		pserverhashmap.UpdateAsync,
		pserverhashmap,
		key,
		function(t: typeof(eep.createprivateserverkeyvalue())?)
			if type(t) ~= "table" then
				t = eep.createprivateserverkeyvalue()
			end

			for k, v in t::any do
				--- print(k, v)
			end

			--- impossible
			assert(t)

			t.key = key
			if type(t.privateserverid) ~= "string" then
				print("reset privateserverid")
				t.privateserverid = ""
			end
			if type(t.accesscode) ~= "string" then
				print("reset accesscode")
				t.accesscode = ""
			end

			if t.privateserverid == "" then
				if isstudio then
					warn("is studio instance, private server will not be reserved")
				else
					local accesscode, privateserverid = TeleportService:ReserveServerAsync(game.PlaceId)
					t.accesscode = accesscode
					t.privateserverid = privateserverid
				end
			end

			print(string.format(
				"%s (keyupdate) pserverhashmap[%s] =",
				scriptname(),
				key
			), t)

			eep.privateservers.keycache[key] = t

			return t
		end,
		pserverstore.expiry
	)
	if keyupdateasyncsuccess then
		if type(keyupdateasyncresult) == "table" then
			local privateserverid = keyupdateasyncresult.privateserverid
			if privateserverid and privateserverid ~= "" then
				local privateserveridupdateasyncsuccess, privateserveridupdateasyncresult = pcall(
					pserverhashmap.UpdateAsync,
					pserverhashmap,
					privateserverid,
					function(t: typeof(eep.createprivateserverprivateserveridvalue())?)
						if type(t) ~= "table" then
							t = eep.createprivateserverprivateserveridvalue()
						end

						--- patch
						for k: any, v: any in eep.createprivateserverprivateserveridvalue()::any do
							if (t::any)[k] == nil then
								(t::any)[k] = v::any
							end
						end

						--- impossible
						assert(t)

						t.key = key
						t.value = value
						t.accesscode = keyupdateasyncresult.accesscode
						t.privateserverid = keyupdateasyncresult.privateserverid

						print(string.format(
							"%s (privateserveridupdate) pserverhashmap[%s] =",
							scriptname(),
							privateserverid::string
						), t)

						eep.privateservers.privateserveridcache[key] = t

						return t
					end,
					pserverstore.expiry
				)
				if privateserveridupdateasyncsuccess then
				else
					warn(scriptname(), "eep.privateserverrefresh privateserveridupdateasync error", privateserveridupdateasyncresult)
				end
			end
			
			print(string.format(
				"%s privateserverpublish result\n> key: %s\n> accesscode: %s\n> privateserverid: %s",
				scriptname()::any,
				key::any,
				keyupdateasyncresult.accesscode,
				keyupdateasyncresult.privateserverid
			))
		end
	else
		warn(scriptname(), "eep.privateserverrefresh keyupdateasync error", keyupdateasyncresult)
	end
end

function eep.privateservergetasync(key: string)
	local pserverstore = eep.privateservers.store

	local pserverhashmap = pserverstore.value
	assert(pserverhashmap and pserverhashmap:IsA("MemoryStoreHashMap"), eep.assertions.badprivateservermemorystore)

	return pcall(
		pserverhashmap.GetAsync,
		pserverhashmap,
		key
	)
end

function eep.privateserveraddinvite(key: string, datamodelkey: string)
	local invitecache = eep.privateservers.stringuseridinvites
	if not invitecache[key] then
		invitecache[key] = {}
	end

	if not table.find(invitecache[key], datamodelkey) then
		table.insert(invitecache[key], datamodelkey)
	end
end

function eep.privateserverreadinvites(key: string)
	local invitecache = eep.privateservers.stringuseridinvites
	return invitecache[key] or {}::{string}
end

function eep.createprivateserverkeyvalue()
	return {
		--- reference to key (intended to be stringuserid) associated with this private server
		key = "";
		--- used to actually teleport to the private server
		accesscode = "";
		--- reference to variant private server data
		privateserverid = "";
	}
end

function eep.createprivateserverprivateserveridvalue()
	return {
		--- reference to key (intended to be stringuserid) associated with this private server
		key = "";
		--- variant value
		value = nil :: any;
		--- static
		roles = {} :: {[string]: number};
		--- used to actually teleport to the private server
		accesscode = "";
		--- reference to variant private server data
		privateserverid = "";
	}
end

--- $$\                                                                       
--- $$ |                                                                      
--- $$$$$$$\   $$$$$$\   $$$$$$\  $$\  $$\  $$\  $$$$$$$\  $$$$$$\   $$$$$$\  
--- $$  __$$\ $$  __$$\ $$  __$$\ $$ | $$ | $$ |$$  _____|$$  __$$\ $$  __$$\ 
--- $$ |  $$ |$$ |  \__|$$ /  $$ |$$ | $$ | $$ |\$$$$$$\  $$$$$$$$ |$$ |  \__|
--- $$ |  $$ |$$ |      $$ |  $$ |$$ | $$ | $$ | \____$$\ $$   ____|$$ |      
--- $$$$$$$  |$$ |      \$$$$$$  |\$$$$$\$$$$  |$$$$$$$  |\$$$$$$$\ $$ |      
--- \_______/ \__|       \______/  \_____\____/ \_______/  \_______|\__|      
---                                                                           
---                                                                           
---                                                                           

--- runs browser heartbeat
function eep.browserheartbeat()
	--- server browser memorystore
	local browserstore = eep.browser.store
	browserstore.value = MemoryStoreService:GetHashMap(browserstore.key)
end

function eep.browsergetasync()
	local browserstore = eep.browser.store

	local browserhashmap = browserstore.value
	assert(browserhashmap and browserhashmap:IsA("MemoryStoreHashMap"), eep.assertions.badbrowsermemorystore)

	local browserpullcache = eep.browser.cache
	table.clear(browserpullcache)

	local result = {}
	for _, continentcode in ipairs(eep.browser.pullrange) do
		local pullregionindex = table.find(eep.browser.continentcodes, continentcode)
		if pullregionindex then
			local key = browserstore.key .. eep.browser.separator .. continentcode

			local getasyncsuccess, getasyncresult = pcall(
				browserhashmap.GetAsync,
				browserhashmap,
				key
			)
			if getasyncsuccess then
				browserpullcache[continentcode] = getasyncresult
				result[continentcode] = getasyncresult
			else
				warn(scriptname(), "eep.browsergetasync error", getasyncresult)
			end
		end
	end

	return result
end

function eep.browsersetasync(regionindex: number, value: any)
	local browserstore = eep.browser.store

	local browserhashmap = browserstore.value
	assert(browserhashmap and browserhashmap:IsA("MemoryStoreHashMap"), eep.assertions.badbrowsermemorystore)

	local continentcode = eep.browser.continentcodes[regionindex] or eep.browser.continentcodes[#eep.browser.continentcodes]
	local key = browserstore.key .. eep.browser.separator .. continentcode

	return pcall(
		browserhashmap.SetAsync,
		browserhashmap,
		key,
		value,
		browserstore.expiry
	)
end

--- to be overwritten externally \
--- clears browser listing associated with this datamodel
function eep.browserclearlisting()
	
end

function eep.readserverregion()
	local index = #eep.browser.continentcodes

	--- ip-api.com
	--[[local query = "http://ip-api.com/json/?fields="
	local field = "countryCode"
	local getasyncsuccess, getasyncresult = pcall(HttpService.GetAsync, HttpService, query .. field)
	if getasyncsuccess then
		local response = HttpService:JSONDecode(getasyncresult)
		if type(response) == "table" then
			local countryiso = response[field] or "??"
			local continentcode = eep.browser.countryisotocontinentcode[countryiso]
			if continentcode then
				index = table.find(eep.browser.continentcodes, continentcode) or #eep.browser.continentcodes
			end
		else
			warn(scriptname(), string.format("getasync response didn't decode into a table (decoded into: %s)", type(response)))
		end
	else
		warn(scriptname(), "readserverregion error:", getasyncresult)
	end]]

	--- ipconfig.io
	local getasyncsuccess, getasyncresult = pcall(HttpService.GetAsync, HttpService, "https://ipconfig.io/json")
	if getasyncsuccess then
		--- print(getasyncresult)
		local response = HttpService:JSONDecode(getasyncresult)
		if type(response) == "table" then
			local countryiso = response.country_iso or "??"
			local continentcode = eep.browser.countryisotocontinentcode[countryiso]
			if continentcode then
				index = table.find(eep.browser.continentcodes, continentcode) or #eep.browser.continentcodes
			end
		else
			warn(scriptname(), string.format("getasync response didn't decode into a table (decoded into: %s)", type(response)))
		end
	else
		warn(scriptname(), "readserverregion error:", getasyncresult)
	end

	return index
end

function eep.createbrowserpacket()
	return {
		--- server jobid
		key = "";
		--- browser value
		value = nil :: any?;
		--- unixtimestampmillis associated with this packet \
		--- should be the time that the packet was sent
		timestamp = 0;
	}
end

--- $$\                           $$\                     $$\                                           $$\           
--- $$ |                          $$ |                    $$ |                                          $$ |          
--- $$ | $$$$$$\   $$$$$$\   $$$$$$$ | $$$$$$\   $$$$$$\  $$$$$$$\   $$$$$$\   $$$$$$\   $$$$$$\   $$$$$$$ | $$$$$$$\ 
--- $$ |$$  __$$\  \____$$\ $$  __$$ |$$  __$$\ $$  __$$\ $$  __$$\ $$  __$$\  \____$$\ $$  __$$\ $$  __$$ |$$  _____|
--- $$ |$$$$$$$$ | $$$$$$$ |$$ /  $$ |$$$$$$$$ |$$ |  \__|$$ |  $$ |$$ /  $$ | $$$$$$$ |$$ |  \__|$$ /  $$ |\$$$$$$\  
--- $$ |$$   ____|$$  __$$ |$$ |  $$ |$$   ____|$$ |      $$ |  $$ |$$ |  $$ |$$  __$$ |$$ |      $$ |  $$ | \____$$\ 
--- $$ |\$$$$$$$\ \$$$$$$$ |\$$$$$$$ |\$$$$$$$\ $$ |      $$$$$$$  |\$$$$$$  |\$$$$$$$ |$$ |      \$$$$$$$ |$$$$$$$  |
--- \__| \_______| \_______| \_______| \_______|\__|      \_______/  \______/  \_______|\__|       \_______|\_______/ 
---                                                                                                                   
---                                                                                                                   
---                                                                                                                   
--- runs leaderboard heartbeat
function eep.leaderboardheartbeat()
	--- leaderboard datastore
	local leaderboardsortedstore = eep.leaderboards.sortedstore
	leaderboardsortedstore.value = DataStoreService:GetDataStore(leaderboardsortedstore.key)
	local leaderboarddatastore = leaderboardsortedstore.value
	
	if leaderboarddatastore and leaderboarddatastore:IsA("DataStore") then
		--- heartbeat
		local function leaderboardheartbeat()
			if eep.readkey("doleaderboardrefresh") ~= true then return end

			if #eep.leaderboards.queue > 0 then
				eep.leaderboardpublishtosortedstore(eep.leaderboards.queue)
			end

			local pullsuccess, pullresult = eep.leaderboardpull()
			if pullsuccess then
				--- ok
				--- print(pullsuccess, pullresult)
			else
				warn(scriptname(), "leaderboard pull error:", pullresult)
			end
		end
		
		framerule(leaderboardsortedstore.heartbeat, -1, leaderboardheartbeat)
	else
		warn(scriptname(), eep.assertions.badpostgamesortedstore)
	end
end

--- creates an empty leaderboard entry \
--- default timestampid is `"global"`
function eep.createleaderboardentry()
	return { timestampid = "global"; scope = "all"; key = nil::any; value = nil::any; sortvalue = -1; }
end

--- pulls leaderboards
function eep.leaderboardpull()
	local leaderboardsortedstore = eep.leaderboards.sortedstore
	leaderboardsortedstore.value = DataStoreService:GetDataStore(leaderboardsortedstore.key)
	local leaderboarddatastore = leaderboardsortedstore.value
	assert(leaderboarddatastore and leaderboarddatastore:IsA("DataStore"), eep.assertions.badleaderboardsortedstore)

	local leaderboardtimestampid = leaderboardsortedstore.timestampid
	if leaderboardtimestampid == "" then
		return false, nil
	end

	local result = {}
	local getasyncsuccess, getasyncresult = pcall(leaderboarddatastore.GetAsync, leaderboarddatastore, leaderboardtimestampid, nil)
	if getasyncsuccess then
		if type(getasyncresult) == "table" then
			for k, v in getasyncresult do
				local truncated = table.create(leaderboardsortedstore.pull)
				table.move(v, 1, leaderboardsortedstore.pull, #truncated + 1, truncated)

				result[k] = truncated
			end
		end

		eep.leaderboardpulled(getasyncresult)
	else
		warn(scriptname(), "eep.leaderboardpull() getasync failure", getasyncresult)
	end

	for k, t in result do
		eep.leaderboards.value[k] = t
	end

	return getasyncsuccess, getasyncresult
end

function eep.leaderboardpulled(pullresult: any)
	
end

function eep.leaderboardcomp(a: typeof(eep.createleaderboardentry()), b: typeof(eep.createleaderboardentry()))
	return a.sortvalue > b.sortvalue
end

--- flushes queued leaderboard entries \
--- sortvalues of -1 (default of `eep.createleaderboardentry()`) are disregarded
function eep.leaderboardpublishtosortedstore(queue: {typeof(eep.createleaderboardentry())})
	local leaderboardsortedstore = eep.leaderboards.sortedstore
	local leaderboarddatastore = leaderboardsortedstore.value
	assert(leaderboarddatastore and leaderboarddatastore:IsA("DataStore"), eep.assertions.badleaderboardsortedstore)

	local leaderboardtimestampid = leaderboardsortedstore.timestampid
	if leaderboardtimestampid == "" then
		return false, nil
	end

	local maxvalues = eep.leaderboards.sortedstore.maxvalues

	--- convert queue into updateasync-able table
	local t = {}
	for i, v in ipairs(eep.leaderboards.queue) do
		local thistimestampid = v.timestampid
		if thistimestampid ~= leaderboardtimestampid then continue end

		table.insert(t, v)
	end

	table.clear(eep.leaderboards.queue)

	local function transform(timestampedleaderboard: {[string]: {typeof(eep.createleaderboardentry())}}?, datastorekeyinfo: DataStoreKeyInfo?)
		if not timestampedleaderboard then
			timestampedleaderboard = {}
		end
		assert(timestampedleaderboard) --- ?

		for _, entry in ipairs(t::{typeof(eep.createleaderboardentry())}) do
			if entry.sortvalue == -1 then continue end

			local scope = entry.scope
			if scope == nil then continue end

			--- nil irrelevant values (already scoped)
			entry.timestampid = nil::any
			entry.scope = nil::any

			--- make scoped table if doesnt exist yet
			if not timestampedleaderboard[scope] then
				timestampedleaderboard[scope] = {}
			end

			--- add (if doesnt exist) or update (if preexisting value with key exists)
			local scopetable = timestampedleaderboard[scope]
			local preexistingupdated = false
			for _, preexisting in scopetable do
				if preexisting.key == entry.key then
					preexistingupdated = true

					--- copy over relevant info
					preexisting.key = entry.key
					preexisting.value = entry.value
					preexisting.sortvalue = entry.sortvalue

					break
				end
			end

			if preexistingupdated then
				--- do nothing
			else
				--- insert
				table.insert(scopetable, entry)
			end
		end

		assert(timestampedleaderboard) --- ?
		for _, scopetable in timestampedleaderboard do
			--- sort
			table.sort(scopetable, eep.leaderboardcomp)

			--- truncate by maxvalues
			for i = #scopetable, maxvalues, -1 do
				table.remove(scopetable, maxvalues)
			end
		end

		return timestampedleaderboard
	end

	return pcall(leaderboarddatastore.UpdateAsync, leaderboarddatastore, leaderboardtimestampid, transform)
end

---                                 $$\                                                 
---                                 $$ |                                                
---  $$$$$$\   $$$$$$\   $$$$$$$\ $$$$$$\    $$$$$$\   $$$$$$\  $$$$$$\$$$$\   $$$$$$\  
--- $$  __$$\ $$  __$$\ $$  _____|\_$$  _|  $$  __$$\  \____$$\ $$  _$$  _$$\ $$  __$$\ 
--- $$ /  $$ |$$ /  $$ |\$$$$$$\    $$ |    $$ /  $$ | $$$$$$$ |$$ / $$ / $$ |$$$$$$$$ |
--- $$ |  $$ |$$ |  $$ | \____$$\   $$ |$$\ $$ |  $$ |$$  __$$ |$$ | $$ | $$ |$$   ____|
--- $$$$$$$  |\$$$$$$  |$$$$$$$  |  \$$$$  |\$$$$$$$ |\$$$$$$$ |$$ | $$ | $$ |\$$$$$$$\ 
--- $$  ____/  \______/ \_______/    \____/  \____$$ | \_______|\__| \__| \__| \_______|
--- $$ |                                    $$\   $$ |                                  
--- $$ |                                    \$$$$$$  |                                  
--- \__|                                     \______/                                   

--- runs postgame sortedstore/recentstore heartbeat
function eep.postgameheartbeat()
	--- postgame datastore
	local postgamesortedstore = eep.postgame.sortedstore
	postgamesortedstore.value = DataStoreService:GetDataStore(postgamesortedstore.key)
	local postgamedatastore = postgamesortedstore.value

	--- postgame recentstore
	local postgamerecentstore = eep.postgame.recentstore
	postgamerecentstore.value = MemoryStoreService:GetHashMap(postgamerecentstore.key)
	
	if postgamedatastore and postgamedatastore:IsA("DataStore") then
		--- heartbeat
		local function postgameheartbeat()
			if eep.readkey("dopostgamerefresh") ~= true then return end

			--- local unixtimestampmillis = DateTime.now().UnixTimestampMillis

			--- wipe nil scopes
			for scope in eep.postgame.value do
				if not table.find(eep.postgame.scopes, scope) then
					eep.postgame.value[scope] = nil
				end
			end

			--- initial pull
			local result = {}
			for _, scope in ipairs(eep.postgame.scopes) do
				local getasyncsuccess, getasyncresult = pcall(postgamedatastore.GetAsync, postgamedatastore, scope, nil)
				if getasyncsuccess then
					local truncated = table.create(postgamesortedstore.pull)

					if type(getasyncresult) == "table" then
						table.move(getasyncresult, 1, postgamesortedstore.pull, #truncated + 1, truncated)
					end

					result[scope] = truncated
				else
					warn(scriptname(), "postgamedatastore getasync error:", getasyncresult)
				end
			end

			--- write
			for scope, values in result do
				eep.postgame.value[scope] = values
			end

			--- print(scriptname(), "postgame values:", eep.postgame.value)
		end
		
		framerule(postgamesortedstore.heartbeat, -1, postgameheartbeat)
	else
		warn(scriptname(), eep.assertions.badpostgamesortedstore)
	end
end

--- creates a postgame value
function eep.createpostgame(value: any)
	return {
		--- postgame key (sharedinstance key)
		key = "";
		--- postgame value
		value = value;
		--- ascending-order sortvalue
		sortvalue = 0;
		--- sortvalue tiebreaker
		timestamp = DateTime.now().UnixTimestampMillis;
	}
end

--- internal table.sort comparison function for sorting `{typeof(eep.createpostgame(...))}`-typed arrays
function eep.postgamecomp(a: typeof(eep.createpostgame(...)), b: typeof(eep.createpostgame(...)))
	if a.sortvalue == b.sortvalue then
		return a.timestamp < b.timestamp
	else
		return a.sortvalue < b.sortvalue
	end
end

--- publishes postgame to postgame recent memorystore
function eep.postgamepublishtorecentstore(pg: typeof(eep.createpostgame(...)), scope: string)
	local postgamerecentstore = eep.postgame.recentstore.value
	assert(postgamerecentstore and postgamerecentstore:IsA("MemoryStoreHashMap"), eep.assertions.badpostgamerecentstore)

	return pcall(postgamerecentstore.SetAsync, postgamerecentstore, pg.key, pg, eep.postgame.recentstore.expiry)
end

--- publishes postgame to postgame pseudo-sorted datastore (leaderboard)
function eep.postgamepublishtosortedstore(pg: typeof(eep.createpostgame(...)), scope: string)
	local postgamesortedstore = eep.postgame.sortedstore.value
	assert(postgamesortedstore and postgamesortedstore:IsA("DataStore"), eep.assertions.badpostgamesortedstore)

	local maxvalues = eep.postgame.sortedstore.maxvalues

	local function transform(list: {typeof(eep.createpostgame())}, datastorekeyinfo: DataStoreKeyInfo?)
		if list then
			if #list < maxvalues then
				table.insert(list, pg)
				table.sort(list, eep.postgamecomp)
			else
				--- sort
				table.sort(list, eep.postgamecomp)
				--- compare slowest time
				if list[#list].sortvalue > pg.sortvalue then
					table.insert(list, pg)

					--- resort and trim
					table.sort(list, eep.postgamecomp)

					for i = #list, maxvalues + 1, -1 do
						table.remove(list, i)
					end
				end
			end

			return list
		else
			return table.create(1, pg)
		end
	end

	return pcall(postgamesortedstore.UpdateAsync, postgamesortedstore, scope, transform)
end

--- pulls set of keys from postgame recent memorystore
function eep.postgamepullrecent(keys: {string})
	local result = table.create(#keys)

	local postgamerecentstore = eep.postgame.recentstore.value
	assert(postgamerecentstore and postgamerecentstore:IsA("MemoryStoreHashMap"), eep.assertions.badpostgamerecentstore)

	for i, key in ipairs(keys) do
		local getasyncsuccess, getasyncresult = pcall(postgamerecentstore.GetAsync, postgamerecentstore, key)
		if getasyncsuccess then
			if type(getasyncresult) ~= nil then
				table.insert(result, key)
			end
		else
			warn(scriptname(), "postgame pullrecent error:", getasyncresult)
		end
	end

	return result
end

return eep