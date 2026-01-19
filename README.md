# eepㅤ/ephemeral entrypoint/

## about

|ico.svg|lore|
|-|-|
|<img src="./eep-ico.svg" width="96"/>|variable ssa entrypoint and activity matchmaking for single-place games|

## gotchas

1. eep must be the first require and variable-ssa entrypoint `eep.main()` must be the first function called on both the server and client.
2. eep is obtuse (>1000 lines, 1 file)
	- ascii annotations have been included for easier file navigation.
	- [special thanks to patorjk for the ascii art generator](https://patorjk.com/software/taag/#p=display&f=Big+Money-nw&t=<3)

## design
is described in reverse order so the behavior of variable-ssa entrypoint `eep.main()` makes sense

### 5. activity
is a ruleset describing:
1. how this datamodel interacts with itself
2. how game-specific code interfaces with eep

```lua
type activity = {
	name: string;
	desc: string;
	rules = {
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
}
```

### 4. datamodelvalue
contains instructions for:
1. how this datamodel percieves itself (`activitykey`)
2. how this datamodel interacts with other datamodels (`sharedinstancekey`)

```lua
type datamodelvalue = {
	activitykey: string;
	sharedinstancekey: string;
}
```

### 3. party
matchmaking component for activities

datamodels whose activity ruleset allows for the matchmaking step to be ran, attempt to claim a "talking stick" such that only 1 datamodel will ever run the matchmaking step.

the matchmaking step is composed of four substeps:<br/>
<i>a zero-th step exists to resync parties using the memorystore party as a truth state</i>

0. prestep:<br/>
resyncs party `userids`, `invites`, and `activitykey` from `datamodel -> memorystore`<br/>
resyncs party `accesscode` from `memorystore -> datamodel`
1. teleport step:<br/>
teleports players, should their associated `party.accesscode ~= ""`, to a reserved server via the aforementioned accesscode
2. allocate step:<br/>
pulls range of parties and attempts to allocate their userids to a `sharedinstance` matching their `activitykey`
3. populate step:<br/>
successfully-allocated `sharedinstances` have servers reserved for all of their peers and the `sharedinstance` is setasync-ed to the sharedinstance memorystore
4. accesscode step:<br/>
populate step function returns a table typed as `{[string partykey]: reservedserveraccesscode}`<br/>
resyncs party `accesscode` from `datamodel -> memorystore`

```lua
type party = {
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
```

### 2. sharedinstance
a pincushion shared by a set of peers (datamodels)

sharedinstances are:
1. designed to terminate (`concludeindex`, `concludetimestamp`, `eep.sharedinstanceattemptconclude()`)
2. intended to sell the illusion of a shared game instance despite its peers (and therefore players/userids) being servers apart

`sharedinstance.peer[index].value` is a variable table designed to be written-to and read-from by game-specific code with the purpose of having it replicate to other peers via the `sharedinstance`

```lua
type sharedinstance = {
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
		}
	};
}
```

### 1. main()
variable-ssa entrypoint

this datamodel will look for its associated `datamodelvalue` and `sharedinstance`. its assigned activitykey (and therefore ruleset) will determine what scripts get ran.

modulescripts are treated as local/server scripts with this entrypoint. however if the modulescript returns a table with function `init`, `init` is pcalled.

file structure:
```
datamodel
├ replicatedfirst
│ └ init.client.luau
│   ├ modulescript1.luau
│   ├ modulescript2.luau
│   └ ...
└ serverscriptservice
  └ init.server.luau
    ├ modulescript1.luau
    ├ modulescript2.luau
    └ ...
```

entrypoint pattern:
```lua
--- init.[script runtime].luau

require(path.to.eep).main(
	{
		__studioactivity = "activity";
		__defaultactivity = "lobby";

		lobby = {
			name = "lobby";
			desc = "matchmaking lobby";
			rules = { ... };
		};
		activity = {
			name = "activity";
			desc = "game activity";
			rules = { ... };
		};
	},
	{
		lobby = { ...ModuleScript };
		activity = { ...ModuleScript };
	}
)
```

---

☁︎ eep by 00826 / overflowed