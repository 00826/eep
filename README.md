# eepㅤ/ephemeral entrypoint/

## about

|ico.svg|lore|
|-|-|
|<img src="./eep-ico.svg" width="96"/>|memorystore-based ssa entrypoint and activity matchmaking for single-place games|

## design

a `datamodel` will look for an associated `datamodelvalue <D>` from a memorystore:
```lua
type datamodelvalue = {
	activitykey: string;
	index: number;
	sharedactivitykey: string;
}
```
`<D>` contains a minimal set of information that is used to determine:
- how this datamodel percieves itself and other datamodels
- how this datamodel interacts with itself and other datamodels

this allows a single-place game to have multiple uses, instead of having to juggle a lobby place, then a game place, etc etc.

---

`datamodel`s may have an associated "shared activity" `<S>`:
```lua
type sharedactivity = {
	key: string;
	timestamp: number;
	instances: {{
		index: number;
		value: {[any]: any}; --- open-ended for developer use

		stringuserids: {string};
		timestamp: number;

		privateserverid: string;
		accesscode: string;
	}};
	
	concludeindex: number;
	concludetimestamp: number;
}
```
where `sharedactivity[datamodelvalue.index] == datamodel's instanced value`

the idea behind this is that a set of datamodels can be given a "shared pincushion" of sorts, that sells the illusion of a shared activity for players despite them being servers apart.

shared activities are capable of being "concluded" for activities that are intended to "terminate" in some form such as a win-loss game like chess.

---

matchmaking was heavily themed after the idea of datamodels being able to claim ownership of a "talking stick", where only one datamodel (should their applied activity ruleset permit it to claim the talking stick) within a set period of time is allowed to run the matchmaking task.

napkin math memorystore unit budgeting, using matchmaking task config:

```lua
eep.matchmakingtask = { --- ඞ
	pull = 200;
	heartbeat = 2;
	--- ... other key-value pairs omitted for legibility
}
```

```md
"worst-case, 200 ccu in 200 servers"
200 == max getpagesasync pull size unit cost
25000 units/min budget == 1000 + (120 * 200)

60 units/min updateasync matchmakingtask == 2 * (60 / 2)
3000 units/min getpagesasync == 200 * (60 / 4)
6000 units/min updateasync == 200 * 2 * (60 / 4)
3000 units/min setasync datamodel 200 * (60 / 4)
3000 units/min setasync shared instance 200 * (60 / 4)

15060 units/min
```

```md
"even worse case, 1 ccu in 1 server"
1 == min getpagesasync pull size unit cost
1120 units/min budget == 1000 + (120 * 1)

60 units/min updateasync matchmakingtask == 2 * (60 / 2)
15 units/min getpagesasync == 1 * (60 / 4)
30 units/min updateasync == 1 * 2 * (60 / 4)
15 units/min setasync datamodel 1 * (60 / 4)
15 units/min setasync shared instance 1 * (60 / 4)

135 units/min
```

## gotchas

1. eep must be the first require and `eep.main()` must be the first function called on both the server and client
```lua
--- require pattern
require(path.to.eep).main(
	{
		__default = "lobby";
		lobby = { ... };
		solo = { ... };
		duo = { ... };
	},
	{
		lobby = { ...ModuleScript };
		activity = { ...ModuleScript };
	}
)
```
2. eep is quite obtuse
	- ascii annotations have been included for easier navigation. [special thanks to patorjk for the ascii art generator](https://patorjk.com/software/taag/#p=display&f=Big+Money-nw&t=<3)

---

☁︎ eep by 00826 / overflowed