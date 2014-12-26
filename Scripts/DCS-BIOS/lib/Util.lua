BIOS.util = {}

function BIOS.util.log2(n)
	return math.log(n) / math.log(2)
end

function BIOS.util.shallowCopy(source, dest)
	dest = dest or {}
	for k, v in pairs(source) do
		dest[k] = v
	end
	return dest
end

function BIOS.util.parse_indication(indicator_id)
	local ret = {}
	local li = list_indication(indicator_id)
	if li == "" then return nil end
	local m = li:gmatch("([^\n]+)\n")
	while true do
		local separator = m()
		if not separator then break end
		local name = m()
		local value = m()
		ret[name] = value
	end
	return ret
end

local function document(args)
	assert(args.identifier)
	assert(args.category)
	if not args.category then args.category = "No Category" end
	if not moduleBeingDefined.documentation[args.category] then moduleBeingDefined.documentation[args.category] = {} end
	moduleBeingDefined.documentation[args.category][args.identifier] = args
end
BIOS.util.document = document

BIOS.util.MemoryMapEntry = {
	address = nil,
	allocatedBitCounter = 0,
	dirty = false,
	allocations = nil
}
function BIOS.util.MemoryMapEntry:create(args)
	assert(args.address)
	self.allocations = {}
	
	local self = BIOS.util.shallowCopy(BIOS.util.MemoryMapEntry)
	self.address = args.address
	return self
end
function BIOS.util.MemoryMapEntry:getValue()
	local ret = 0
	for _, alloc in pairs(self.allocations) do
		if alloc.value ~= nil then ret = ret + (alloc.value * alloc.multiplier) end
	end
	return ret
end
function BIOS.util.MemoryMapEntry:setDirtyIfAble()
	for _, alloc in pairs(self.allocations) do
		if alloc.value ~= nil then
			self.dirty = true
			return
		end
	end
end
function BIOS.util.MemoryMapEntry:allocate(args)
	assert(args.maxValue)
	
	local bitsRequired = math.ceil(BIOS.util.log2(args.maxValue+1))
	assert(bitsRequired <= (16 - self.allocatedBitCounter))
	local shiftBy = self.allocatedBitCounter
	--local shiftBy = (16 - self.allocatedBitCounter - bitsRequired)
	local alloc = BIOS.util.shallowCopy(BIOS.util.MemoryAllocation)
	alloc.address = self.address
	alloc.maxValue = args.maxValue
	alloc.memoryMapEntry = self
	alloc.multiplier = math.pow(2, shiftBy)
	alloc.mask = (math.pow(2, bitsRequired) - 1) * math.pow(2, shiftBy)
	alloc.shiftBy = shiftBy
	self.allocatedBitCounter = self.allocatedBitCounter + bitsRequired
	self.allocations[#self.allocations+1] = alloc
	return alloc
end

BIOS.util.MemoryAllocation = {
	value = nil,
	memoryMapEntry = nil,
	maxValue = nil,
	multiplier = nil
}
function BIOS.util.MemoryAllocation:setValue(value)
	assert(self.maxValue)
	assert(value)
	value = math.floor(value)
	if value < 0 then
		BIOS.log(string.format("value %f is too small for address %d mask %d", value, self.address, self.mask))
		return
	end
	if value > self.maxValue then
		BIOS.log(string.format("value %f is too large for address %d mask %d", value, self.address, self.mask))
		return
	end
	assert(value >= 0)
	assert(value <= self.maxValue)
	if self.value ~= value then
		self.value = value
		self.memoryMapEntry.dirty = true
	end
end

BIOS.util.StringAllocation = {
	characterAllocations = nil
}
function BIOS.util.StringAllocation:setValue(value)
	local i = 1
	while i <= value:len() and i <= #self.characterAllocations do
		self.characterAllocations[i]:setValue(value:byte(i))
		i = i + 1
	end
	if value:len() < #self.characterAllocations then
		-- null-terminate
		self.characterAllocations[value:len()+1]:setValue(0)
	end
end

BIOS.util.MemoryMap = {
	baseAddress = nil,
	autosyncPosition = nil
}
function BIOS.util.MemoryMap:create(args)
	assert(args.baseAddress)
	
	local self = BIOS.util.shallowCopy(BIOS.util.MemoryMap)
	self.baseAddress = args.baseAddress
	self.lastAddress = self.baseAddress
	self.autosyncPosition = self.baseAddress
	self.entries = {
		[self.baseAddress] = BIOS.util.MemoryMapEntry:create{address = self.baseAddress}
	}
	return self
end
function BIOS.util.MemoryMap:autosyncStep()
	-- set a non-dirty value to dirty
	self.autosyncPosition = self.autosyncPosition + 2
	if self.autosyncPosition > self.lastAddress then
		self.autosyncPosition = self.baseAddress -- wrap around
	end
	local entry = self:getEntry(self.autosyncPosition)
	entry:setDirtyIfAble()
end
function BIOS.util.MemoryMap:flushData()
	-- Return a string containing a sequence of write accesses
	-- that contain all entries marked as dirty.
	-- Resets the "dirty bit".
	
	local ret = ""
	
	local address = self.baseAddress
	local entry = self:getEntry(address)

	-- advance to the first entry that has changed
	while address <= self.lastAddress do
		entry = self:getEntry(address)
		if entry.dirty then break end
		address = address + 2
	end
	if not entry.dirty then
		-- no changes at all
		return ""
	end
	
	-- prepare write access
	local writeStartAddress = address
	local writeLength = 2
	local writeData = BIOS.util.encodeInt(entry:getValue())
	local lastWriteDataAddress = address
	entry.dirty = false
	address = address + 2
	
	while address <= self.lastAddress do
		entry = self:getEntry(address)
		--BIOS.log("LOOP 2: address = "..tostring(address)..", lastAddress = "..tostring(self.lastAddress))
		-- advance to the next changed value
		if entry.dirty then
			-- figure out whether to start a new write request
			if (address - lastWriteDataAddress <= 6) and entry:getValue() ~= 0x5555 then
				-- append to current write request
				local a = lastWriteDataAddress + 2
				while a <= address do
					writeLength = writeLength + 2
					writeData = writeData .. BIOS.util.encodeInt(self:getEntry(a):getValue())
					a = a + 2
				end
				lastWriteDataAddress = address
				assert(address == a-2)
			else
				-- start new write request
				ret = ret .. BIOS.util.encodeInt(writeStartAddress) .. BIOS.util.encodeInt(writeLength) .. writeData
				writeStartAddress = address
				writeLength = 2
				writeData = BIOS.util.encodeInt(entry:getValue())
				lastWriteDataAddress = address
			end
			entry.dirty = false
		end
		address = address + 2
	end
	
	return ret .. BIOS.util.encodeInt(writeStartAddress) .. BIOS.util.encodeInt(writeLength) .. writeData
end
function BIOS.util.MemoryMap:getEntry(address)
	if self.entries[address] == nil then
		-- initialize new entry
		self.entries[address] = BIOS.util.MemoryMapEntry:create{ address = address }
		self.lastAddress = address
	end
	return self.entries[address]
end
function BIOS.util.MemoryMap:clearValues()
	for _, entry in pairs(self.entries) do
		for _, alloc in pairs(entry.allocations) do
			alloc.value = nil
			alloc.dirty = false
		end
	end
end
function BIOS.util.MemoryMap:allocateInt(args)
	-- allocate space for an integer value from 0 to args.maxValue in the memory map
	-- returns a MemoryAllocation object that has a setValue() method
	-- if args.allocateStringCharacter is true, the allocation will be in a byte-aligned
	-- position at the end of the memory map. Consecutive calls with args.allocateStringCharacter
	-- set will allocate consecutive bytes in the memory map.
	assert(args.maxValue)
	
	local bitsRequired = math.ceil(BIOS.util.log2(args.maxValue+1))
	local address = nil
	if args.allocateStringCharacter then
		address = self.lastAddress
	else
		address = self.baseAddress
	end
	
	while true do
		local entry = self:getEntry(address)
		
		local cannotFitValue = (16 - entry.allocatedBitCounter) < bitsRequired
		local invalidCharacterAllocation = args.allocateStringCharacter and not (entry.allocatedBitCounter == 0 or entry.allocatedBitCounter == 8)
		invalidCharacterAllocation = invalidCharacterAllocation or (args.allocateFirstStringCharacter and entry.allocatedBitCounter ~= 0)
		if cannotFitValue or invalidCharacterAllocation then
			address = address + 2
		else
			-- found an entry that has enough space for the number of bits we want to allocate
			return entry:allocate{ maxValue = args.maxValue }
		end
	end
end
function BIOS.util.MemoryMap:allocateString(args)
	assert(args.maxLength)
	
	local stringAlloc = BIOS.util.shallowCopy(BIOS.util.StringAllocation)
	stringAlloc.characterAllocations = {}
	
	stringAlloc.characterAllocations[1] = self:allocateInt{ maxValue = 255, allocateStringCharacter = true, allocateFirstStringCharacter = true }
	for i = 2, args.maxLength, 1 do
		stringAlloc.characterAllocations[i] = self:allocateInt{ maxValue = 255, allocateStringCharacter = true }
	end
	stringAlloc.address = stringAlloc.characterAllocations[1].address
	stringAlloc.maxLength = args.maxLength
	return stringAlloc
end


function BIOS.util.defineIndicatorLight(msg, arg_number, category, description)
	--moduleBeingDefined.highFrequencyMap[msg] = function(dev0) return string.format("%.0f", dev0:get_argument_value(arg_number)) end
	local value = moduleBeingDefined.memoryMap:allocateInt {
		maxValue = 1
	}
	assert(value.shiftBy ~= nil)
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		value:setValue(dev0:get_argument_value(arg_number))
	end
	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "led",
		inputs = {},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = value.address,
			  mask = value.mask,
			  shift_by = value.shiftBy,
			  max_value = 1,
			  description = "0 if light is off, 1 if light is on"
			}
		}
	}
end

function BIOS.util.definePushButton(msg, device_id, device_command, arg_number, category, description)
	--moduleBeingDefined.highFrequencyMap[msg] = function(dev0) return string.format("%.0f", dev0:get_argument_value(arg_number)) end
	moduleBeingDefined.inputProcessors[msg] = function(state)
		if type(state) == "string" then state = tonumber(state) end
		GetDevice(device_id):performClickableAction(device_command, state)
	end
	local value = moduleBeingDefined.memoryMap:allocateInt {
		maxValue = 1
	}
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		value:setValue(dev0:get_argument_value(arg_number))
	end	
	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "selector",
		api_variant = "momentary_last_position",
		physical_variant = "push_button",
		inputs = {
			{ interface = "set_state", max_value = 1, description = "set the state of the button (1 = pushed, 0 = released)" },
		},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = value.address,
			  mask = value.mask,
			  shift_by = value.shiftBy,
			  max_value = 1,
			  description = "0 in released state, 1 in pushed state"
			}
		}
	}

end

function BIOS.util.definePotentiometer(msg, device_id, command, arg_number, limits, category, description)
	--moduleBeingDefined.lowFrequencyMap[msg] = function(dev0) return string.format("%.4f", dev0:get_argument_value(arg_number)) end
	if limits == nil then limits = {0.0, 1.0} end
	moduleBeingDefined.inputProcessors[msg] = function(value)
		local newValue = ((GetDevice(0):get_argument_value(arg_number) - limits[1]) / intervalLength) * 65535
		if value:match("-[0-9]+") or value:match("%+[0-9]+") then
			newValue = BIOS.util.cap(newValue + tonumber(value), {0, 65535})
		elseif value:match("[0-9]+") then
			newValue = BIOS.util.cap(tonumber(value), {0, 65535})
		end
		
		GetDevice(device_id):performClickableAction(command, value/65535*intervalLength + limits[1])
	end
	
	local intervalLength = limits[2] - limits[1]
	local value = moduleBeingDefined.memoryMap:allocateInt {
		maxValue = 65535
	}
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		value:setValue(((dev0:get_argument_value(arg_number) - limits[1]) / intervalLength) * 65535)
	end
	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "limited_dial",
		inputs = {
			{ interface = "set_state", max_value = 65535, description = "set the position of the dial" },
			{ interface = "variable_step", max_value = 65535, suggested_step = 3200, description = "turn the dial left or right" },
		},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = value.address,
			  mask = value.mask,
			  shift_by = value.shiftBy,
			  max_value = 65535,
			  description = "position of the potentiometer"
			}
		}
	}
end

function BIOS.util.defineRotary(msg, device_id, command, arg_number, category, description)
	--moduleBeingDefined.lowFrequencyMap[msg] = function(dev0) return string.format("%.4f", dev0:get_argument_value(arg_number)) end
	moduleBeingDefined.inputProcessors[msg] = function(value)
		GetDevice(device_id):performClickableAction(command, tonumber(value)/65535)
	end
	local value = moduleBeingDefined.memoryMap:allocateInt {
		maxValue = 65535
	}

	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "analog_dial",
		api_variant = "multiturn",
		inputs = {
			{ interface = "variable_step", max_value = 65535, suggested_step = 3200, description = "turn the dial left or right" },
		},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "_KNOB_POS",
			  address = value.address,
			  mask = value.mask,
			  shift_by = value.shiftBy,
			  max_value = 65535,
			  description = "the rotation of the knob in the cockpit (not the value that is controlled by this knob!)"
			}
		}
	}

	--document { msg = msg, category = category, description = description, msg_type = "rotary", value_type = "float", value_range = {0, 1}, can_set = false, actions = {"DEC", "INC"}, address = value.address, mask = value.mask }
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		value:setValue(dev0:get_argument_value(arg_number) * 65535)
	end
end

local function cap(value, limits, cycle)
	if cycle then
		if value < limits[1] then return limits[2] end
		if value > limits[2] then return limits[1] end
	else
		if value <= limits[1] then return limits[1] end
		if value >= limits[2] then return limits[2] end
	end
	return value
end
BIOS.util.cap = cap

function BIOS.util.defineSetCommandTumb(msg, device_id, command, arg_number, step, limits, output_map, cycle, category, description)
	-- uses SetCommand and set_argument_value instead of performClickableAction()
	local span = limits[2] - limits[1]
	local last_n = tonumber(string.format("%.0f", span / step))

	local value_enum = output_map
	if not value_enum then
		value_enum = {}
		local n = 0
		while n <= last_n do
			value_enum[#value_enum+1] = tostring(n)
			n = n + 1
		end
	end
	
	local enumAlloc = moduleBeingDefined.memoryMap:allocateInt{ maxValue = last_n }
	local strAlloc = nil
	if output_map then
		local max_len = 0
		for i = 1,#output_map,1 do
			if max_len < output_map[i]:len() then max_len = output_map[i]:len() end
		end
		strAlloc = moduleBeingDefined.memoryMap:allocateString{ maxLength = max_len }
	end
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		local value = dev0:get_argument_value(arg_number)		
		local n = tonumber(string.format("%.0f", (value - limits[1]) / step))
		
		if n > last_n then n = last_n end
		enumAlloc:setValue(n)
		if strAlloc then
			strAlloc:setValue(output_map[n+1])
		end
	end
	
	--document { msg = msg, category = category, description = description, msg_type = "tumb", value_type = "enum", value_enum = value_enum, can_set = true, actions = {"DEC", "INC"}, enum_address = enumAlloc.address, enum_mask = enumAlloc.mask }
	
	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "selector",
		momentary_positions = "none",
		inputs = {
			{ interface = "fixed_step", description = "switch to previous or next state" },
			{ interface = "set_state", max_value = last_n, description = "set position" },
		},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = enumAlloc.address,
			  mask = enumAlloc.mask,
			  shift_by = enumAlloc.shiftBy,
			  max_value = last_n,
			  description = "selector position"
			}
		}
	}
	local docentry = moduleBeingDefined.documentation[category][msg]
	if cycle then
		docentry.physical_variant = "infinite_rotary"
	else
		docentry.physical_variant = "limited_rotary"
	end
	if output_map then
		docentry.outputs[1].suffix = "_INT"
		docentry.outputs[2] = {
			["type"] = "string",
			suffix="_STR",
			address = strAlloc.address,
			max_length = strAlloc.maxLength,
			description = "possible values: "
		}
		for i=1,#output_map,1 do
			docentry.outputs[2].description = docentry.outputs[2].description .. '"'..output_map[i]..'" '
		end
	end
	
	moduleBeingDefined.inputProcessors[msg] = function(state)
		local value = GetDevice(0):get_argument_value(arg_number)		
		local n = tonumber(string.format("%.0f", (value - limits[1]) / step))
		local new_n = n
		if state == "INC" then
			new_n = cap(n+1, {0, last_n}, cycle)
			if cycle == "skiplast" and new_n == last_n then new_n = 0 end
		
			GetDevice(device_id):SetCommand(command, limits[1] + step*new_n)
			GetDevice(0):set_argument_value(arg_number, limits[1] + step*new_n)
		elseif state == "DEC" then
			new_n = cap(n-1, {0, last_n}, cycle)
			if cycle == "skiplast" and new_n == last_n then new_n = last_n - 1 end
			
			GetDevice(device_id):SetCommand(command, limits[1] + step*new_n)
			GetDevice(0):set_argument_value(arg_number, limits[1] + step*new_n)
		else
			n = tonumber(string.format("%.0f", tonumber(state)))
			if n == nil then return end
			GetDevice(device_id):SetCommand(command, limits[1] + step*cap(n, {0, last_n}, cycle))
			GetDevice(0):set_argument_value(arg_number, limits[1] + step*cap(n, {0, last_n}, cycle))
		end
	end
end

function BIOS.util.defineTumb(msg, device_id, command, arg_number, step, limits, output_map, cycle, category, description)
	local span = limits[2] - limits[1]
	local last_n = tonumber(string.format("%.0f", span / step))
	
	local value_enum = output_map
	if not value_enum then
		value_enum = {}
		local n = 0
		while n <= last_n do
			value_enum[#value_enum+1] = tostring(n)
			n = n + 1
		end
	end
	
	local enumAlloc = moduleBeingDefined.memoryMap:allocateInt{ maxValue = last_n }
	local strAlloc = nil
	if output_map then
		local max_len = 0
		for i = 1,#output_map,1 do
			if max_len < output_map[i]:len() then max_len = output_map[i]:len() end
		end
		strAlloc = moduleBeingDefined.memoryMap:allocateString{ maxLength = max_len }
	end
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		local value = dev0:get_argument_value(arg_number)		
		local n = tonumber(string.format("%.0f", (value - limits[1]) / step))
		
		if n > last_n then n = last_n end
		enumAlloc:setValue(n)
		if strAlloc then
			strAlloc:setValue(output_map[n+1])
		end
	end
	
	--document { msg = msg, category = category, description = description, msg_type = "tumb", value_type = "enum", value_enum = value_enum, can_set = true, actions = {"DEC", "INC"}, enum_address = enumAlloc.address, enum_mask = enumAlloc.mask }
	

	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "selector",
		momentary_positions = "none",
		inputs = {
			{ interface = "fixed_step", description = "switch to previous or next state" },
			{ interface = "set_state", max_value = last_n, description = "set position" },
		},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = enumAlloc.address,
			  mask = enumAlloc.mask,
			  shift_by = enumAlloc.shiftBy,
			  max_value = last_n,
			  description = "selector position"
			}
		}
	}
	local docentry = moduleBeingDefined.documentation[category][msg]
	if cycle then
		docentry.physical_variant = "infinite_rotary"
	else
		docentry.physical_variant = "limited_rotary"
	end
	if last_n == 1 then
		docentry.inputs[#docentry.inputs+1] = { interface = "action", argument = "TOGGLE", description = "Toggle switch state" }
	end
	if output_map then
		docentry.outputs[1].suffix = "_INT"
		docentry.outputs[2] = {
			["type"] = "string",
			suffix="_STR",
			address = strAlloc.address,
			max_length = strAlloc.maxLength,
			description = "possible values: "
		}
		for i=1,#output_map,1 do
			docentry.outputs[2].description = docentry.outputs[2].description .. '"'..output_map[i]..'" '
		end
	end
	
	moduleBeingDefined.inputProcessors[msg] = function(state)
		local value = GetDevice(0):get_argument_value(arg_number)		
		local n = tonumber(string.format("%.0f", (value - limits[1]) / step))
		local new_n = n
		if state == "INC" then
			new_n = cap(n+1, {0, last_n}, cycle)
			if cycle == "skiplast" and new_n == last_n then new_n = 0 end
		
			GetDevice(device_id):performClickableAction(command, limits[1] + step*new_n)
		elseif state == "DEC" then
			new_n = cap(n-1, {0, last_n}, cycle)
			if cycle == "skiplast" and new_n == last_n then new_n = last_n - 1 end
			
			GetDevice(device_id):performClickableAction(command, limits[1] + step*new_n)
		elseif state == "TOGGLE" then
			if n == 0 then new_n = 1 elseif n == 1 then new_n = 0 end
			GetDevice(device_id):performClickableAction(command, limits[1] + step*new_n)
		else
			n = tonumber(string.format("%.0f", tonumber(state)))
			if n == nil then return end
			GetDevice(device_id):performClickableAction(command, limits[1] + step*cap(n, {0, last_n}, cycle))
		end
	end
end

function BIOS.util.defineToggleSwitch(msg, device_id, command, arg_number, category, description)
	BIOS.util.defineTumb(msg, device_id, command, arg_number, 1, {0, 1}, nil, false, category, description)
	local docentry = moduleBeingDefined.documentation[category][msg]
	docentry.physical_variant = "toggle_switch"
end

function BIOS.util.defineToggleSwitchToggleOnly(msg, device_id, command, arg_number, category, description)
	BIOS.util.defineTumb(msg, device_id, command, arg_number, 1, {0, 1}, nil, false, category, description)
	moduleBeingDefined.documentation[category][msg].control_type = "action"
	local docentry = moduleBeingDefined.documentation[category][msg]
	docentry.inputs = {
		{ interface = "action", argument = "TOGGLE", description = "toggle switch state" }
	}
	
	moduleBeingDefined.inputProcessors[msg] = function(state)
		if state == "TOGGLE" then
			GetDevice(device_id):performClickableAction(command, 1)
		end
	end
end

function BIOS.util.defineRelativeTumb(msg, device_id, command, arg_number, step, limits, rel_args, output_map, category, description)
	BIOS.util.defineTumb(msg, device_id, command, arg_number, step, limits, output_map, true, category, description)
	local docentry = moduleBeingDefined.documentation[category][msg]
	assert(docentry.inputs[2].interface == "set_state")
	docentry.inputs[2] = nil
	moduleBeingDefined.documentation[category][msg].control_type = "discrete_dial"
	
	moduleBeingDefined.inputProcessors[msg] = function(state)
		if state == "DEC" then
			GetDevice(device_id):performClickableAction(command, rel_args[1])
		elseif state == "INC" then
			GetDevice(device_id):performClickableAction(command, rel_args[2])
		end
	end
end

function BIOS.util.defineString(msg, getter, maxLength, category, description)
	--moduleBeingDefined.lowFrequencyMap[msg] = getter
	local alloc = moduleBeingDefined.memoryMap:allocateString{ maxLength = maxLength }
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		alloc:setValue(getter(dev0))
	end
	--document { msg = msg, category = category, description = description, msg_type = "string", value_type = "string", can_set = false, actions = {}, address = alloc.address, max_length = alloc.max_length }

	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "display",
		inputs = {},
		outputs = {
			{ ["type"] = "string",
			  suffix = "",
			  address = alloc.address,
			  mask = alloc.mask,
			  shift_by = alloc.shiftBy,
			  max_length = alloc.maxLength,
			  description = description
			}
		}
	}
	
end

function BIOS.util.defineElectricallyHeldSwitch(msg, device_id, pos_command, neg_command, arg_number, category, description)
	local alloc = moduleBeingDefined.memoryMap:allocateInt{ maxValue = 1 }
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		alloc:setValue(dev0:get_argument_value(arg_number))
	end
	--document { msg = msg, category = category, description = description, msg_type = "electrically_held_switch", value_type = "enum", value_enum = {"0", "1"}, can_set = false, actions = {"PUSH", "RELEASE", "OFF"} }
	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "electrically_held_switch",
		inputs = {
			{ interface = "action", argument = "PUSH", description = "push and hold the switch in the ON position" },
			{ interface = "action", argument = "RELEASE", description = "release the switch" },
			{ interface = "action", argument = "OFF", description = "put the switch in the OFF position" }
		},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = alloc.address,
			  mask = alloc.mask,
			  shift_by = alloc.shiftBy,
			  max_value = 1,
			  description = "switch position -- 0 = off, 1 = on"
			}
		}
	}
	--moduleBeingDefined.lowFrequencyMap[msg] = function(dev0) return string.format("%.0f", dev0:get_argument_value(arg_number)) end
	moduleBeingDefined.inputProcessors[msg] = function(action)
		if action == "PUSH" then GetDevice(device_id):performClickableAction(pos_command, 1) end
		if action == "RELEASE" then GetDevice(device_id):performClickableAction(neg_command, 0) end
		if action == "OFF" then GetDevice(device_id):performClickableAction(pos_command, 0) end
	end
end

function BIOS.util.defineRockerSwitch(msg, device_id, pos_command, pos_stop_command, neg_command, neg_stop_command, arg_number, category, description)
	--document { msg = msg, category = category, description = description, msg_type = "rocker", value_type = "enum", value_enum = {"0", "1", "2"}, can_set = true, actions = {} }
	--moduleBeingDefined.lowFrequencyMap[msg] = function(dev0)
	--	local lut = {["-1"] = "0", ["0"] = "1", ["1"] = "2"}
	--	return lut[string.format("%.0f", dev0:get_argument_value(arg_number))]
	--end
	local alloc = moduleBeingDefined.memoryMap:allocateInt{ maxValue = 2 }
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		local lut = {["-1"] = "0", ["0"] = "1", ["1"] = "2"}
		alloc:setValue(lut[string.format("%.0f", dev0:get_argument_value(arg_number))])
	end
	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "selector",
		momentary_positions = "first_and_last",
		physical_variant = "rocker_switch",
		inputs = {
			{ interface = "set_state", max_value = 2, description = "set the switch position -- 0 = held left/down, 1 = centered, 2 = held right/up" },
		},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = alloc.address,
			  mask = alloc.mask,
			  shift_by = alloc.shiftBy,
			  max_value = 2,
			  description = "selector position"
			}
		}
	}
	moduleBeingDefined.inputProcessors[msg] = function(toState)
		if toState == "0" then
			toState = -1
		elseif toState == "1" then
			toState = 0
		elseif toState == "2" then
			toState = 1
		else
			return
		end
		local fromState = GetDevice(0):get_argument_value(arg_number)
		local dev = GetDevice(device_id)
		if fromState == 0 and toState == 1 then dev:performClickableAction(pos_command, 1) end
		if fromState == 1 and toState == 0 then dev:performClickableAction(pos_stop_command, 0) end
		if fromState == 0 and toState == -1 then dev:performClickableAction(neg_command, -1) end
		if fromState == -1 and toState == 0 then dev:performClickableAction(neg_stop_command, 0) end
		if fromState == -1 and toState == 1 then
			dev:performClickableAction(neg_stop_command, 0)
			dev:performClickableAction(pos_command, 1)
		end
		if fromState == 1 and toState == -1 then
			dev:performClickableAction(pos_stop_command, 0)
			dev:performClickableAction(neg_command, -1)
		end
	end
end

function BIOS.util.defineMultipositionSwitch(msg, device_id, device_command, arg_number, num_positions, increment, category, description)
	BIOS.util.defineTumb(msg, device_id, device_command, arg_number, increment, {0, increment*(num_positions-1)}, nil, false, category, description)
	local docentry = moduleBeingDefined.documentation[category][msg]
	docentry.physical_variant = "toggle_switch"
end

function BIOS.util.encodeInt(intval)
	assert(intval >= 0)
	assert(intval <= 65535)
	-- convert value (a float from 0.0 to 1.0) to a 16-bit signed integer from 0 to 65535
	local lowbyte = intval % 256
	local highbyte = (intval - lowbyte) / 256
	return string.char(lowbyte, highbyte)
end

function BIOS.util.defineFloat(msg, arg_number, limits, category, description)
	local intervalLength = limits[2] - limits[1]
	--moduleBeingDefined.lowFrequencyMap[msg] = function(dev0) return encode01Float(dev0:get_argument_value(arg_number)) end--string.format("%.4f", dev0:get_argument_value(arg_number)) end
	local alloc = moduleBeingDefined.memoryMap:allocateInt { maxValue = 65535 }
	moduleBeingDefined.exportHooks[#moduleBeingDefined.exportHooks+1] = function(dev0)
		alloc:setValue(((dev0:get_argument_value(arg_number) - limits[1]) / intervalLength) * 65535)
	end
	document {
		identifier = msg,
		category = category,
		description = description,
		control_type = "analog_gauge",
		inputs = {},
		outputs = {
			{ ["type"] = "integer",
			  suffix = "",
			  address = alloc.address,
			  mask = alloc.mask,
			  shift_by = alloc.shiftBy,
			  max_value = 65535,
			  description = "gauge position"
			}
		}
	}
	--document { msg = msg, category = category, description = description, msg_type = "int", value_type = "int", value_range = limits, can_set = false, actions = {}, address = alloc.address }
end