--[[ description:

  - a lightweight, fully-typed serialization library for Roblox
  - the type functions are especially useful when building higher-level abstractions on top of the library
  - this module was specially created as a foundational component for my framework. it may not suit your workflow

]]
--!strict


--// types
--functions
type function getinnerof(ty: type)
	if ty:is("any") or ty:is("nil") then
		return ty
	end

	if ty:is("table") then
		return ty:readproperty(types.singleton("__inner")) :: type
	elseif ty:is("intersection") or ty:is("union") then
		for _, component in ty:components() do
			local inner = getinnerof(component)
			if inner then
				return inner
			end
		end
	else
		return ty
	end

	error("Could not get type")
end

type function getinnerlist(ty: type)
	local out = types.newtable()

	if ty:is("intersection") or ty:is("union") then
		for _, component in ty:components() do
			for key, prop in getinnerlist(component):properties() do
				out:setproperty(key, prop)
			end
		end
	elseif ty:is("table") then
		for key, prop in ty:properties() do
			local propType = prop.write or prop.read
			if propType then
				local inner = getinnerof(propType)
				if inner then
					out:setproperty(key, inner)
				end
			end
		end
	end

	return out
end

type function writeable(ty: type)
	local out = types.newtable()

	if ty:is("table") then
		for key, prop in ty:properties() do
			if prop.write then
				out:setproperty(key, types.optional(prop.write))
			end
		end
	elseif ty:is("intersection") then
		for _, component in ty:components() do
			for key, prop in component:properties() do
				out:setproperty(key, prop.write)
			end
		end
	end

	return out
end

export type innerof<T> = getinnerof<T>
export type innerlist<T> = getinnerlist<T>

--native
export type schema<inner = any> = {
	__inner: inner,
	serialize: (writer, value: inner) -> (),
	deserialize: (reader) -> inner,
	validate: (any) -> boolean
}

export type writer = {
	buf: buffer?,
	offset: number,

	bits: (self: writer, bits: number, value: number) -> (),
	schema: (self: writer, schema: any, any) -> (),
	section: (self: writer, (writer) -> ()) -> (),
	alignByte: (self: writer) -> (),
	byteCount: (self: writer) -> number,

	bool: (self: writer, value: boolean) -> (),
	u8: (self: writer, value: number) -> (),
	u16: (self: writer, value: number) -> (),
	u32: (self: writer, value: number) -> ()
}

export type readContext = {
	player: Player?
}

export type reader = {
	buf: buffer,
	offset: number,
	limit: number,

	bits: (self: reader, bits: number) -> number,
	schema: (self: reader, schema: any) -> any,
	section: (self: reader, (reader) -> ()) -> (),
	alignByte: (self: reader) -> (),
	skipBits: (self: reader, buts: number) -> (),

	bool: (self: reader) -> boolean,
	u8: (self: reader) -> number,
	u16: (self: reader) -> number,
	u32: (self: reader) -> number
}


--// root
local schemas = {}

local function unsignedCountBits(value: number): number
	assert(value >= 0 and value % 1 == 0)

	local bits = 0
	repeat
		bits += 1
		value //= 2
	until value == 0

	return bits
end


--// primitives
schemas.bool = {
	serialize = function(writer: writer, value: boolean)
		writer:bits(1, value == true and 1 or 0)
	end,
	deserialize = function(reader: reader)
		return reader:bits(1) == 1
	end,
	validate = function(value: any)
		return type(value) == "boolean"
	end,
} :: schema<boolean>

function schemas.unsigned(bits: number)
	return {
		serialize = function(writer: writer, value: number)
			writer:bits(bits, value)
		end,
		deserialize = function(reader: reader)
			return reader:bits(bits)
		end,
		validate = function(value)
			return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 2 ^ bits - 1
		end,
	} :: schema<number>
end

function schemas.signed(bits: number)
	local shift = 2 ^ bits
	return {
		serialize = function(writer: writer, value: number)
			if value <= 0 then
				value += shift
			end
			writer:bits(bits, value)
		end,
		deserialize = function(reader: reader)
			local value = reader:bits(bits)
			if value > shift then
				value -= shift
			end
			return value
		end,
		validate = function(value)
			return type(value) == "number" 
				and value % 1 == 0 and value >= -(2 ^ (bits - 1)) 
				and value <= 2 ^ (bits - 1) - 1
		end,
	} :: schema<number>
end

schemas.u8 = schemas.unsigned(8)
schemas.u16 = schemas.unsigned(16)
schemas.u32 = schemas.unsigned(32)
schemas.i8 = schemas.signed(8)
schemas.i16 = schemas.signed(16)
schemas.i32 = schemas.signed(32)

function schemas.range(min: number, max: number)
	local bits = math.ceil(math.log(max - min, 2))
	local shift = min < 0 and min or 0
	
	return {
		serialize = function(writer: writer, value: number)
			writer:bits(bits, value + shift)
		end,
		deserialize = function(reader: reader)
			return reader:bits(bits) - shift
		end,
		validate = function(value)
			return type(value) == "number" and value >= min and value <= max
		end,
	} :: schema<number>
end

function schemas.decimal(integerBits: number, decimalPlaces: number)
	local scale = 10 ^ decimalPlaces

	local maxInteger = 2 ^ integerBits - 1
	local maxValue = maxInteger + ((scale - 1) / scale)

	local maxPacked = (maxInteger * scale) + (scale - 1)
	local totalBits = math.ceil(math.log(maxPacked + 1, 2))
	
	return {
		serialize = function(writer: writer, value: number)
			writer:bits(totalBits, math.round(value * scale))
		end,
		deserialize = function(reader: reader)
			return reader:bits(totalBits) / scale
		end,
		validate = function(value)
			return type(value) == "number" and value >= 0 and value <= maxValue
		end,
	} :: schema<number>
end

function schemas.string(maxLength: number)
	local lengthBits = unsignedCountBits(maxLength)
	return {
		serialize = function(writer: writer, value: string)
			local length = #value
			writer:bits(lengthBits, length)
			writer:alignByte()
			if writer.buf then
				print(debug.traceback())
				buffer.writestring(writer.buf, writer.offset // 8, value, length)
			end
			writer.offset += length * 8
		end,
		deserialize = function(reader: reader)
			local length = reader:bits(lengthBits)
			reader:alignByte()
			if reader.offset + length * 8 > reader.limit then
				error(`exceeded limit by {reader.offset + length * 8 - reader.limit} bits`)
			end
			local value = buffer.readstring(reader.buf, reader.offset // 8, length)
			reader.offset += length * 8
			return value
		end,
		validate = function(value)
			return type(value) == "string" and #value <= maxLength
		end,
	} :: schema<string>
end

function schemas.enum<T>(values: T)
	local valuesByName = values :: { [string]: number }
	local namesByValue: { [number]: string } = {}
	local maxValue = 0

	for name, id in valuesByName do
		assert(type(id) == "number" and id % 1 == 0 and id >= 0, "enum ids must be unsigned integers")
		assert(namesByValue[id] == nil, "duplicate enum id")
		namesByValue[id] = name
		maxValue = math.max(maxValue, id)
	end

	local bits = unsignedCountBits(maxValue)
	
	return {
		serialize = function(writer: writer, value: any)
			writer:bits(bits, valuesByName[value])
		end,
		deserialize = function(reader: reader)
			local id = reader:bits(bits)
			local name = namesByValue[id]
			if name == nil then
				error(`unknown enum id {id}`)
			end
			return name
		end,
		validate = function(value)
			return type(value) == "string" and valuesByName[value] ~= nil
		end
	} :: schema<keyof<T>>
end


-------------------------------------------------------
--// composites

export type optional<T> = schema<T?>

function schemas.optional<T>(schema: T)
	local schema = schema :: schema
	return {
		serialize = function(writer: writer, value: any?)
			writer:bool(value ~= nil)
			if value ~= nil then
				schema.serialize(writer, value)
			end
		end,
		deserialize = function(reader: reader)
			local present = reader:bool()
			if not present then
				return nil
			end
			return schema.deserialize(reader)
		end,
		validate = function(value)
			return value == nil or schema.validate(value)
		end,
	} :: optional<T>
end


-------------------------------------------------------
--// containers

export type container<K = any, V = any> = schema<{ [K]: V }> & { [K]: V }

function schemas.array<V>(maxLength: number, valueSchema: V)
	local valueSchema = valueSchema :: schema
	local countSchema = schemas.unsigned(unsignedCountBits(maxLength))
	
	return {
		serialize = function(writer: writer, elements: { [number]: innerof<V> })
			local len = #elements
			countSchema.serialize(writer, len)
			for i = 1, len do
				valueSchema.serialize(writer, elements[i])
			end
		end,
		deserialize = function(reader: reader)
			local out: { [number]: innerof<V> } = {}
			for i = 1, countSchema.deserialize(reader) do
				out[i] = valueSchema.deserialize(reader)
			end
			return out
		end,
		validate = function(elements: { [any]: any })
			if type(elements) ~= "table" then
				return false
			end
			
			local n = #elements
			if n > maxLength then
				return false
			end
			
			for i = 1, n do
				if not valueSchema.validate(elements[i]) then
					return false
				end
			end

			for k in pairs(elements) do
				if type(k) ~= "number"
					or k % 1 ~= 0
					or k < 1
					or k > n then
					return false
				end
			end
			
			return true
		end,
	} :: container<number, V>
end

function schemas.map<K, V>(keySchema: K, valueSchema: V, maxLength: number?)
	local keySchema, valueSchema = keySchema :: schema, valueSchema :: schema
	local maxLength = maxLength or 2 ^ 32
	local countSchema = schemas.unsigned(unsignedCountBits(maxLength))
	
	return {
		serialize = function(writer: writer, entries: { [innerof<K>]: innerof<V> })
			local len = 0; for _ in entries do len += 1 end
			countSchema.serialize(writer, len)
			for k, v in entries do
				keySchema.serialize(writer, k)
				valueSchema.serialize(writer, v)
			end
		end,
		deserialize = function(reader: reader)
			local out: { [innerof<K>]: innerof<V> } = {}
			for _ = 1, countSchema.deserialize(reader) do
				out[keySchema.deserialize(reader)] = valueSchema.deserialize(reader)
			end
			return out
		end,
		validate = function(entries: { [any]: any })
			if type(entries) ~= "table" then
				return false
			end
			
			local i = 0
			for k, v in entries do
				i += 1
				if not keySchema.validate(k) then
					return false
				end
				if not valueSchema.validate(v) then
					return false
				end
			end
			
			if i > maxLength then
				return false
			end
			
			return true
		end,
	} :: container<K, V>
end


-------------------------------------------------------
--// structs
--[[

	- this implementation of structs are slightly unorthodox
	- they were designed to support partial writes rather than explicitly require full snapshots

]]

export type struct<shape = any> = setmetatable<schema<shape>, { __index: shape }>

function schemas.struct<shape>(shape: shape)
	local shape = shape :: { [string]: schema }

	type field = {
		id: number,
		key: string,
		schema: schema
	}
	
	local fieldsById: { field } = {}
	local fieldsByKey: { [string]: field } = {}

	for key, schema in shape do
		local field = {
			key = key,
			schema = schema
		} :: field

		table.insert(fieldsById, field)
		fieldsByKey[key] = field
	end

	table.sort(fieldsById, function(a: field, b: field)
		return a.key < b.key
	end)
	
	for id, field in ipairs(fieldsById) do
		field.id = id
	end
	
	return {
		serialize = function(writer: writer, fields: { [string]: any })
			local len = 0; for _ in fields do len += 1 end
			writer:u16(len)
			
			for key, value in fields do
				local field = fieldsByKey[key]
				writer:u16(field.id)
				writer:schema(field.schema, value)
			end
		end,
		deserialize = function(reader: reader)
			local out = {}
			for _ = 1, reader:u16() do
				local id = reader:u16()
				local field = fieldsById[id]
				out[field.key] = reader:schema(field.schema)
			end
			return out :: innerlist<shape>
		end,
		validate = function(fields: { [any]: any })
			if type(fields) ~= "table" then
				return false
			end
			
			for key, value in fields do
				local field = fieldsByKey[key]
				if not field then
					return false
				end
				
				if not field.schema.validate(value) then
					return false
				end
			end
			
			return true
		end,
	} :: struct<shape>
end



-------------------------------------------------------
--// networking

function schemas.writer(buf: buffer?)
	local writer = {
		buf = buf,
		offset = 0,
	} :: writer

	function writer:bits(bitCount: number, value: number)
		if self.buf then
			buffer.writebits(self.buf, self.offset, bitCount, value)
		end
		self.offset += bitCount
	end

	function writer:bool(value: boolean)
		self:bits(1, value and 1 or 0)
	end

	function writer:schema(schema: any, value: any)
		print(value)
		schema.serialize(writer, value)
	end

	function writer:u8(value)
		self:bits(8, value)
	end

	function writer:u16(value)
		self:bits(16, value)
	end

	function writer:u32(value)
		self:bits(32, value)
	end

	function writer:alignByte()
		local remainder = self.offset % 8
		if remainder ~= 0 then
			self.offset += 8 - remainder
		end
	end

	-- section format: u32 bitLength, then payload
	-- this costs 32 bits per dynamic section, but makes route/container skipping super simple
	function writer:section(write: (writer) -> ())
		local counter = schemas.writer(nil)
		write(counter)

		self:bits(32, counter.offset)
		write(self)
	end

	function writer:byteCount(): number
		return math.ceil(self.offset / 8)
	end

	return writer
end

function schemas.reader(buf: buffer, bitLimit: number?): reader
	local reader = {
		buf = buf,
		offset = 0,
		limit = bitLimit or (buffer.len(buf) * 8),
	} :: reader

	function reader:bits(bitCount: number): number
		if self.offset + bitCount > self.limit then
			error(`reader overflow: tried to read {self.offset + bitCount - self.limit} bits past section limit`)
		end
		local value = buffer.readbits(self.buf, self.offset, bitCount)
		self.offset += bitCount
		return value
	end

	function reader:bool(): boolean
		return self:bits(1) == 1
	end

	function reader:schema(schema: any): any
		return schema.deserialize(self)
	end

	function reader:u8()
		return self:bits(8)
	end

	function reader:u16()
		return self:bits(16)
	end

	function reader:u32()
		return self:bits(32)
	end

	function reader:alignByte()
		local remainder = self.offset % 8
		if remainder ~= 0 then
			self.offset += 8 - remainder
		end
		if self.offset > self.limit then
			error("reader overflow after byte alignment")
		end
	end

	function reader:skipBits(bitCount: number)
		self.offset = math.min(self.offset + bitCount, self.limit)
	end

	function reader:section(readPayload: (reader) -> ())
		local bitCount = self:bits(32)
		local start = self.offset
		local sectionLimit = start + bitCount

		if sectionLimit > self.limit then
			error("section exceeds parent reader limit")
		end

		local sectionReader = schemas.reader(self.buf, sectionLimit)
		sectionReader.offset = start

		local ok, err = pcall(function()
			readPayload(sectionReader)
		end)

		-- always land exactly at the end of the section, even on failure
		self.offset = sectionLimit

		if not ok then
			warn(`network section read failed and was skipped: {err}`)
		end
	end

	return reader
end

function schemas.buildBuffer(write: (writer) -> ()): buffer
	local counter = schemas.writer(nil)
	write(counter)

	local buf = buffer.create(counter:byteCount())
	local writer = schemas.writer(buf)
	write(writer)

	assert(writer.offset == counter.offset, "count/write pass mismatch")
	return buf
end


--// return
return schemas
