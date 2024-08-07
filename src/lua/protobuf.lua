local ffi = require('ffi')
local wireformat = require('internal.protobuf.wireformat')
local protocol_mt
-- These constants are used to define the boundaries of valid field ids.
-- Described in more detail here:
-- https://protobuf.dev/programming-guides/proto3/#assigning
local MIN_FIELD_ID = 1
local RESERVED_FIELD_ID_MIN = 19000
local RESERVED_FIELD_ID_MAX = 19999
local MAX_FIELD_ID = 2^29 - 1

-- Number limits for int32 and int64
local MAX_FLOAT = 0x1.fffffep+127
local MAX_UINT32 = 2^32 - 1
-- Actual uint64 limit is 2^64 - 1. Because of lua number limited precision
-- numbers from [2^64 - 1024, 2^64 + 2048] represent as 2^64. So the correct
-- number limit for uint64 is 2^64 - 1025.
local MAX_UINT64 = 0xfffffffffffffbff
local MIN_SINT32 = -2^31
local MAX_SINT32 = 2^31 - 1
-- Same problem with lua number limited precision.
-- Numbers from [2^63 - 512, 2^63 + 1024] represent as 2^63. So the correct
-- number limit for int64 is 2^63 - 513.
local MAX_INT64 = 0x7ffffffffffffdff
local MIN_INT64 = -0x8000000000000000 -- 2^63

-- Cdata limits for int32_t and int64_t
local MAX_UINT32_LL = 2LL^32 - 1
local MAX_UINT32_ULL = 2ULL^32 - 1
local MIN_SINT32_LL = -2LL^31
local MAX_SINT32_LL = 2LL^31 - 1
local MAX_SINT32_ULL = 2ULL^31 - 1
local MAX_SINT64_ULL = 2ULL^63 - 1


local int64_t = ffi.typeof('int64_t')
local uint64_t = ffi.typeof('uint64_t')

-- Forward declarations
local encode
local encode_field
local validate_scalar

local scalars = {}

-- {{{ Scalar type definitions

scalars.float = {
    accept_type = 'number',
    encode_as_packed = true,
    integral_only = false,
    limits = {
        number = {-MAX_FLOAT, MAX_FLOAT},
    },
    encode = wireformat.encode_float,
}

scalars.fixed32 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {0, MAX_UINT32},
        int64 = {0LL, MAX_UINT32_LL},
        uint64 = {nil, MAX_UINT32_ULL},
    },
    encode = wireformat.encode_fixed32,
}

scalars.sfixed32 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {MIN_SINT32, MAX_SINT32},
        int64 = {MIN_SINT32_LL, MAX_SINT32_LL},
        uint64 = {nil, MAX_SINT32_ULL},
    },
    encode = wireformat.encode_fixed32,
}

scalars.double = {
    accept_type = 'number',
    encode_as_packed = true,
    integral_only = false,
    encode = wireformat.encode_double,
}

scalars.fixed64 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {0, MAX_UINT64},
        int64 = {0LL, nil},
    },
    encode = wireformat.encode_fixed64,
}

scalars.sfixed64 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {MIN_INT64, MAX_INT64},
        uint64 = {nil, MAX_SINT64_ULL},
    },
    encode = wireformat.encode_fixed64,
}

scalars.string = {
    accept_type = 'string',
    encode_as_packed = false,
    encode = wireformat.encode_len,
}

scalars.bytes = scalars.string

scalars.int32 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {MIN_SINT32, MAX_SINT32},
        int64 = {MIN_SINT32_LL, MAX_SINT32_LL},
        uint64 = {nil, MAX_SINT32_ULL},
    },
    encode = wireformat.encode_int,
}

scalars.sint32 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {MIN_SINT32, MAX_SINT32},
        int64 = {MIN_SINT32_LL, MAX_SINT32_LL},
        uint64 = {nil, MAX_SINT32_ULL},
    },
    encode = wireformat.encode_sint,
}

scalars.uint32 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {0, MAX_UINT32},
        int64 = {0LL, MAX_UINT32_LL},
        uint64 = {nil, MAX_UINT32_ULL},
    },
    encode = wireformat.encode_int,
}

scalars.int64 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {MIN_INT64, MAX_INT64},
        uint64 = {nil, MAX_SINT64_ULL},
    },
    encode = wireformat.encode_int,
}

scalars.sint64 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {MIN_INT64, MAX_INT64},
        uint64 = {nil, MAX_SINT64_ULL},
    },
    encode = wireformat.encode_sint,
}

scalars.uint64 = {
    accept_type = {'number', 'cdata'},
    encode_as_packed = true,
    integral_only = true,
    limits = {
        number = {0, MAX_UINT64},
        int64 = {0LL, nil},
    },
    encode = wireformat.encode_int,
}

scalars.bool = {
    accept_type = 'boolean',
    encode_as_packed = true,
    encode = wireformat.encode_int,
}

-- }}} Scalar type definitions


-- {{{ Constructors: message, enum, protocol

-- Create a message object suitable to pass
-- into the protobuf.protocol function.
--
-- Accepts a name of the message and a message
-- definition in the following format.
--
-- message_def = {
--    <field_name> = {<field_type>, <field_id>},
--    <...>
-- }
local function message(message_name, message_def)
    local field_by_name = {}
    local field_by_id = {}
    for field_name, def in pairs(message_def) do
        local field_type = def[1]
        local field_id = def[2]
        local field_type, rep = string.gsub(field_type, 'repeated%s', '')
        if field_by_id[field_id] ~= nil then
            error(('Id %d in field %q was already used'):format(field_id,
                field_name))
        end
        if field_id < MIN_FIELD_ID or field_id > MAX_FIELD_ID then
            error(('Id %d in field %q is out of range [%d; %d]'):format(
                field_id, field_name, MIN_FIELD_ID, MAX_FIELD_ID))
        end
        if field_id >= RESERVED_FIELD_ID_MIN and
           field_id <= RESERVED_FIELD_ID_MAX then
           error(('Id %d in field %q is in reserved ' ..
               'id range [%d, %d]'):format(field_id, field_name,
               RESERVED_FIELD_ID_MIN, RESERVED_FIELD_ID_MAX))
        end
        local field_def = {
            type = field_type,
            name = field_name,
            id = field_id,
        }
        if rep ~= 0 then
            field_def['repeated'] = true
        end
        field_by_name[field_name] = field_def
        field_by_id[field_id] = field_def
    end
    return {
        type = 'message',
        name = message_name,
        field_by_name = field_by_name,
        field_by_id = field_by_id
    }
end

-- Create a enum object suitable to pass into
-- the protobuf.protocol function.
--
-- Accepts a name of an enum and an enum definition
-- in the following format.
--
-- enum_def = {
--     <value_name> = <value_id>,
--     <...>
-- }
local function enum(enum_name, enum_def)
    local id_by_value = {}
    local value_by_id = {}
    for value_name, value_id in pairs(enum_def) do
        if value_by_id[value_id] ~= nil then
            error(('Double definition of enum field %q by %d'):format(
                value_name, value_id))
        end
        local field_def = {type = 'int32', name = value_name}
        validate_scalar(field_def, value_id)
        id_by_value[value_name] = value_id
        value_by_id[value_id] = value_name
    end
    if value_by_id[0] == nil then
        error(('%q definition does not contain a field with id = 0'):
            format(enum_name))
    end
    return {
        type = 'enum',
        name = enum_name,
        id_by_value = id_by_value,
        value_by_id = value_by_id,
    }
end

-- Create a protocol object that stores message
-- data needed for encoding.
--
-- Accepts protocol definition using protobuf.message
-- and protobuf.enum functions as in example.
--
-- protocol_def = {
--     protocol.message(<message_name>, <message_def>),
--     protocol.enum(<enum_name>, <enum_def>),
--     <...>
-- }
--
-- Returns a table of the following structure:
--
-- protocol = {
--     ['MessageName_1'] = {
--         type = 'message'
--         name = 'MessageName_1'
--         field_by_name = {
--             ['FieldName_1'] = <..field_def..>,
--             ['FieldName_2'] = <..field_def..>,
--             <...>
--         },
--         field_by_id = {
--             [1] = <..field_def..>,
--             [2] = <..field_def..>,
--             <...>
--         },
--     },
--     ['EnumName_1'] = {
--         type = 'enum'
--         name = 'EnumName_1'
--         id_by_value = {
--             [<string>] = <number>,
--             [<string>] = <number>,
--             <...>
--         },
--         value_by_id = {
--             [<number>] = <string>,
--             [<number>] = <string>,
--             <...>
--         },
--     },
--     <...>
-- }
--
-- where <..field_def..> is a table of following structure:
--
-- field_def = {
--     type = 'MessageName' or 'EnumName' or 'int64' or <...>,
--     name = <string>,
--     id = <number>,
--     repeated = nil or true,
-- }
local function protocol(protocol_def)
    local res = {}
    -- Declaration table is used to check forward declarations
    -- false -- this type used as the field type in the message was not defined
    -- true -- this field type was defined
    local declarations = {}
    for _, def in pairs(protocol_def) do
        if declarations[def.name] then
            error(('Double definition of name %q'):format(def.name))
        end
        if def.type == 'message' then
            for _, field_def in pairs(def.field_by_id) do
                local standard = scalars[field_def.type] ~= nil
                local declared = declarations[field_def.type]
                if not standard and not declared then
                    declarations[field_def.type] = false
                end
            end
        end
        declarations[def.name] = true
        res[def.name] = def
    end
    -- Detects a message or a enum that is used as a field type in message
    -- but not defined in protocol. Allows a type be defined after usage
    for def_type, declared in pairs(declarations) do
        if not declared then
            error(('Type %q is not declared'):format(def_type))
        end
    end
    return setmetatable(res, protocol_mt)
end

-- }}} Constructors: message, enum, protocol


-- {{{ Global helpers

local function is_number64(value)
    return type(value) == 'cdata' and (ffi.istype(int64_t, value) or
        ffi.istype(uint64_t, value))
end

local function is_nan(value)
    assert(type(value) == 'number')
    return value ~= value
end

local function is_inf(value)
    assert(type(value) == 'number')
    return not is_nan(value) and is_nan(value - value)
end

-- Checks input value assumed to be integer.
--
-- Checks 'number' type value to be integral and 'cdata' type value to be
-- number64 (look function above). Assumes a value of 'number' or 'cdata'
-- type as an input.
local function check_integer(field_def, value)
    if type(value) == 'number' and math.ceil(value) ~= value then
        error(('Input number value %f for %q is not integer'):format(
            value, field_def.name))
    elseif type(value) == 'cdata' and not is_number64(value) then
        error(('Input cdata value %q for %q field is not integer'):format(
            ffi.typeof(value), field_def.name))
    end
end

local function remove_tag(value)
    local tag_length = 0
    repeat
        tag_length = tag_length + 1
        local msb = bit.band(string.byte(value, tag_length), 0x80)
    until msb == 0
    return string.sub(value, tag_length + 1)
end

-- }}} Global helpers


-- {{{ is_scalar, is_enum, is_message

local function is_scalar(field_def)
    return scalars[field_def.type]
end

local function is_enum(protocol, field_def)
    return protocol[field_def.type].type == 'enum'
end

local function is_message(protocol, field_def)
    return protocol[field_def.type].type == 'message'
end

-- }}} is_scalar, is_enum, is_message


-- {{{ Validation

local function validate_length(value)
    local MAX_LEN = 2^32
    if string.len(value) > MAX_LEN then
        error("Too long string to be encoded")
    end
end

local function validate_table_is_array(field_def, value)
    assert(type(value) == 'table')
    local key_count = 0
    local min_key = math.huge
    local max_key = -math.huge
    for k, data in pairs(value) do
        if data == box.NULL then
            error(('Input array for %q repeated field contains box.NULL ' ..
                'value which leads to ambiguous behaviour'):format(
                field_def.name))
        end
        if type(k) ~= 'number' then
            error(('Input array for %q repeated field ' ..
                'contains non-numeric key: %q'):format(field_def.name, k))
        end
        if k - math.floor(k) ~= 0 then
            error(('Input array for %q repeated field contains ' ..
                'non-integer numeric key: %q'):format(field_def.name, k))
        end
        key_count = key_count + 1
        min_key = math.min(min_key, k)
        max_key = math.max(max_key, k)
    end
    if key_count == 0 then
        return
    end
    if min_key ~= 1 then
        error(('Input array for %q repeated field got min index %d. ' ..
            'Must be 1'):format(field_def.name, min_key))
    end
    if max_key ~= key_count then
        error(('Input array for %q repeated field has inconsistent keys. ' ..
            'Got table with %d fields and max index of %d'):format(
            field_def.name, key_count, max_key))
    end
end

local function validate_type(field_def, value, exp_type)
    if type(exp_type) == 'table' then
        local found = false
        for _, exp_t in pairs(exp_type) do
            if type(value) == exp_t then
                found = true
                break
            end
        end
        if not found then
            error(('Field %q of %q type gets %q type value.'):format(
                field_def.name, field_def.type, type(value)))
        end
        return
    end
    assert(type(exp_type) == 'string')
    if type(value) ~= exp_type then
        error(('Field %q of %q type gets %q type value.'):format(
            field_def.name, field_def.type, type(value)))
    end
    return
end

local function validate_range(field_def, value, range)
    local min = range ~= nil and range[1] or nil
    local max = range ~= nil and range[2] or nil
    -- If one of the limits is 'nil' this function skips
    -- the comparison with this limit
    --
    -- NB: We can't use -math.huge instead of nil for the lower limit,
    -- because, for example, 10ULL < -math.huge returns true.
    if min ~= nil and value < min or max ~= nil and value > max then
        error(('Input data for %q field is %q and do not fit in %q')
            :format(field_def.name, value, field_def.type))
    end
end

validate_scalar = function(field_def, value)
    local scalar_def = scalars[field_def.type]
    local value_type = type(value)
    assert(scalar_def.accept_type ~= nil)
    -- Checks type of input according to the allowed types for this field.
    validate_type(field_def, value, scalar_def.accept_type)
    -- Checks length of the string if input type assumed to be string.
    if scalar_def.accept_type == 'string' then
        validate_length(value)
    end
    -- Checks number values for being NaN or inf.
    if value_type == 'number' and is_nan(value) then
        error(('Input data for %q field is NaN'):format(field_def.name))
    end
    if value_type == 'number' and is_inf(value) then
        error(('Input data for %q field is inf'):format(field_def.name))
    end
    -- Checks values assumed to be integer.
    if scalar_def.integral_only then
        check_integer(field_def, value)
    end
    -- Checks numeric values to see if they belong to the limits.
    if scalar_def.limits ~= nil then
        if value_type == 'cdata' then
            value_type = ffi.istype(int64_t, value) and 'int64'
                or 'uint64'
        end
        validate_range(field_def, value, scalar_def.limits[value_type])
    end
end

-- }}} Validation


-- {{{ Encoders

local function encode_repeated(protocol, field_def, value)
    local buf = {}
    local encode_as_packed = false
    if type(value) ~= 'table' then
        error('For repeated fields table data are needed')
    end
    validate_table_is_array(field_def, value)
    if is_scalar(field_def) then
        local scalar_def = scalars[field_def.type]
        encode_as_packed = scalar_def.encode_as_packed
    end
    for _, item in ipairs(value) do
        local encoded_item = encode_field(protocol, field_def, item, true)
        if encoded_item == '' then
            error(('Input for %q repeated field contains default value ' ..
                'can`t be encoded correctly'):format(field_def.name))
        end
        if encode_as_packed then
            encoded_item = remove_tag(encoded_item)
        end
        table.insert(buf, encoded_item)
    end
    if encode_as_packed then
        return wireformat.encode_len(field_def.id, table.concat(buf))
    else
        return table.concat(buf)
    end
end

local function encode_enum(protocol, field_def, value)
    local id = protocol[field_def.type]['id_by_value'][value]
    if type(value) ~= 'number' and id == nil then
        error(('%q is not defined in %q enum'):format(value, field_def.type))
    end
    -- According to open enums semantics unknown enum values are encoded as
    -- numeric identifier. https://protobuf.dev/programming-guides/enum/
    if type(value) == 'number' then
        local subs_field_def = {type = 'int32', id = field_def.id}
        validate_scalar(subs_field_def, value)
        return scalars['int32'].encode(field_def.id, value)
    else
        return scalars['int32'].encode(field_def.id, id)
    end
end

encode_field = function(protocol, field_def, value, ignore_repeated)
    if field_def.repeated and not ignore_repeated then
        return encode_repeated(protocol, field_def, value)
    elseif is_scalar(field_def) then
        validate_scalar(field_def, value)
        local scalar_def = scalars[field_def.type]
        return scalar_def.encode(field_def.id, value)
    elseif is_enum(protocol, field_def) then
        return encode_enum(protocol, field_def, value)
    elseif is_message(protocol, field_def) then
        local encoded_msg = encode(protocol, field_def.type, value)
        validate_length(encoded_msg)
        return wireformat.encode_len(field_def.id, encoded_msg, true)
    else
        assert(false)
    end
end

-- Encodes the entered data in accordance with the
-- selected protocol into binary format.
--
-- Accepts a protocol created by protobuf.protocol function,
-- a name of a message selected for encoding and
-- the data that needs to be encoded in the following format.
--
-- data = {
--     <field_name> = <value>,
--     <...>
-- }
encode = function(protocol, message_name, data)
    local buf = {}
    local message_def = protocol[message_name]
    if message_def == nil then
        error(('There is no message or enum named %q in the given protocol')
            :format(message_name))
    end
    if message_def.type ~= 'message' then
        assert(message_def.type == 'enum')
        error(('Attempt to encode enum %q as a top level message'):format(
            message_name))
    end
    local field_by_name = message_def.field_by_name
    for field_name, value in pairs(data) do
        if value == box.NULL then goto continue end
        if field_by_name[field_name] == nil and
            field_name ~= '_unknown_fields' then
                error(('Wrong field name %q for %q message'):
                    format(field_name, message_name))
        end
        if field_name == '_unknown_fields' then
            table.insert(buf, table.concat(value))
        else
            table.insert(buf, encode_field(protocol,
                field_by_name[field_name], value, false))
        end
        ::continue::
    end
    return table.concat(buf)
end

-- }}} Encoders

protocol_mt = {
    __index = {
        encode = encode,
    }
}

return {
    message = message,
    enum = enum,
    protocol = protocol,
}
