# schemas
a lightweight, fully-typed serialization library for Roblox

> [!CAUTION]
> i created this as a foundational component for my framework. it may not suit your workflow
## example usage
```luau
local schemas = require(path.to.schemas)

local player = schemas.struct {
  name = schemas.string(32),
	level = schemas.u8,
	coins = schemas.u32,
	inventory = schemas.array(16, schemas.string(20)),
}

local data = {
	name = "finch",
	level = 10,
	coins = 2500,
	inventory = {
		"Sword",
		"Potion",
	}
}

assert(Player.validate(data))

local buffer = schemas.buildBuffer(function(writer)
	writer:schema(Player, data)
end)

local result = schemas.reader(buffer):schema(Player)

print(result.name) --> Finch
print(result.coins) --> 2500
```
