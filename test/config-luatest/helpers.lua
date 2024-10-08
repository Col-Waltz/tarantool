local fun = require('fun')
local yaml = require('yaml')
local fio = require('fio')
local cluster_config = require('internal.config.cluster_config')
local t = require('luatest')
local treegen = require('luatest.treegen')
local justrun = require('luatest.justrun')
local server = require('luatest.server')

local function group(name, params)
    local g = t.group(name, params)

    g.after_each(function(g)
        for k, v in pairs(table.copy(g)) do
            if k == 'server' or k:match('^server_%d+$') then
                v:stop()
                g[k] = nil
            end
        end
    end)

    return g
end

local function run_as_script(f)
    return function()
        local dir = treegen.prepare_directory({}, {})
        treegen.write_file(dir, 'myluatest.lua', string.dump(function()
            local t = require('luatest')

            -- Luatest raises a table as an error. If the error is
            -- not caught, it looks like the following on stderr.
            --
            -- LuajitError: table: 0x41b2ce08
            -- fatal error, exiting the event loop
            --
            -- Moreover, if the message is too long it is
            -- truncated at converting to box error. See
            -- DIAG_ERRMSG_MAX in src/lib/core/diag.h, it is 512
            -- at the time of writing.
            --
            -- Let's write the message on stderr and re-raise a
            -- short message instead.
            local saved_assert_equals = t.assert_equals
            t.assert_equals = function(...)
                local ok, err = pcall(saved_assert_equals, ...)
                if ok then
                    return
                end
                if type(err) == 'table' and type(err.message) == 'string' then
                    err = err.message
                end
                io.stderr:write(err .. '\n')
                error('See stderr output above', 2)
            end

            return t
        end))
        treegen.write_file(dir, 'main.lua', string.dump(f))

        local opts = {nojson = true, stderr = true}
        local res = justrun.tarantool(dir, {}, {'main.lua'}, opts)
        t.assert_equals(res.exit_code, 0, {res.stdout, res.stderr})
    end
end


local function start_example_replicaset(g, dir, config_file, opts)
    local credentials = {
        user = 'client',
        password = 'secret',
    }
    local opts = fun.chain({
        config_file = config_file,
        chdir = dir,
        net_box_credentials = credentials,
    }, opts or {}):tomap()
    g.server_1 = server:new(fun.chain(opts, {alias = 'instance-001'}):tomap())
    g.server_2 = server:new(fun.chain(opts, {alias = 'instance-002'}):tomap())
    g.server_3 = server:new(fun.chain(opts, {alias = 'instance-003'}):tomap())

    g.server_1:start({wait_until_ready = false})
    g.server_2:start({wait_until_ready = false})
    g.server_3:start({wait_until_ready = false})

    g.server_1:wait_until_ready()
    g.server_2:wait_until_ready()
    g.server_3:wait_until_ready()

    local info = g.server_1:eval('return box.info')
    t.assert_equals(info.name, 'instance-001')
    t.assert_equals(info.replicaset.name, 'replicaset-001')

    local info = g.server_2:eval('return box.info')
    t.assert_equals(info.name, 'instance-002')
    t.assert_equals(info.replicaset.name, 'replicaset-001')

    local info = g.server_3:eval('return box.info')
    t.assert_equals(info.name, 'instance-003')
    t.assert_equals(info.replicaset.name, 'replicaset-001')
end

-- A simple single instance configuration.
local simple_config = {
    credentials = {
        users = {
            guest = {
                roles = {'super'},
            },
        },
    },
    iproto = {
        listen = {{uri = 'unix/:./{{ instance_name }}.iproto'}}
    },
    groups = {
        ['group-001'] = {
            replicasets = {
                ['replicaset-001'] = {
                    instances = {
                        ['instance-001'] = {},
                    },
                },
            },
        },
    },
}

local function prepare_case(opts)
    local dir = opts.dir
    local roles = opts.roles
    local script = opts.script
    local options = opts.options
    local env = opts.env

    if dir == nil then
        dir = treegen.prepare_directory({}, {})
    end

    if roles ~= nil and next(roles) ~= nil then
        for name, body in pairs(roles) do
            treegen.write_file(dir, name .. '.lua', body)
        end
    end

    if script ~= nil then
        treegen.write_file(dir, 'main.lua', script)
    end

    local config = simple_config
    if options ~= nil then
        config = table.deepcopy(simple_config)
        for path, value in pairs(options) do
            cluster_config:set(config, path, value)
        end
    end

    treegen.write_file(dir, 'config.yaml', yaml.encode(config))
    local config_file = fio.pathjoin(dir, 'config.yaml')

    local server = {
        config_file = config_file,
        chdir = dir,
        env = env,
        alias = 'instance-001',
    }
    local justrun = {
        -- dir
        dir,
        -- env
        env or {},
        -- args
        {'--name', 'instance-001', '--config', config_file},
        -- opts
        {nojson = true, stderr = true},
    }
    return {
        dir = dir,
        server = server,
        justrun = justrun,
    }
end

-- Start a server with the given script and the given
-- configuration, run a verification function on it.
--
-- * opts.roles
--
--   Role codes for writing into corresponding files.
--
-- * opts.script
--
--   Code write into the main.lua file.
--
-- * opts.options
--
--   The configuration is expressed as a set of path:value pairs.
--   It is merged into the simple config above.
--
-- * opts.verify
--
--   Function to run on the started server to verify some
--   invariants.
--
-- * opts.verify_args
--
--  Arguments for the verify function.
--
-- * opts.env
--
--   Environment variables to set for the child process.
local function success_case(g, opts)
    local verify = assert(opts.verify)
    local prepared = prepare_case(opts)
    g.server = server:new(prepared.server)
    g.server:start()
    g.server:exec(verify, opts.verify_args)
    return prepared
end

-- Start tarantool process with the given script/config and check
-- the error.
--
-- * opts.roles
-- * opts.script
-- * opts.options
-- * opts.env
--
--   Same as in success_case().
--
-- * opts.exp_err
--
--   An error that must be written into stderr by tarantool
--   process.
local function failure_case(opts)
    local exp_err = assert(opts.exp_err)

    local prepared = prepare_case(opts)
    local res = justrun.tarantool(unpack(prepared.justrun))
    t.assert_equals(res.exit_code, 1)
    t.assert_str_contains(res.stderr, exp_err)
end

-- Start a server, write a new script/config, reload, run a
-- verification function.
--
-- * opts.roles
-- * opts.script
-- * opts.options
-- * opts.verify
-- * opts.verify_args
-- * opts.env
--
--   Same as in success_case().
--
-- * opts.roles_2
--
--   A new list of roles to prepare before config:reload().
--
-- * opts.script_2
--
--   A new script to write into the main.lua file before
--   config:reload().
--
-- * opts.options_2
--
--   A new config to use for the config:reload(). It is optional,
--   if not provided opts.options is used instead.
--
-- * opts.verify_2
--
--   Verify test invariants after config:reload().
--
-- * opts.verify_args_2
--
--   Arguments for the second verify function.
local function reload_success_case(g, opts)
    local roles_2 = opts.roles_2
    local script_2 = opts.script_2
    local options = assert(opts.options)
    local verify_2 = assert(opts.verify_2)
    local verify_args_2 = opts.verify_args_2
    local options_2 = opts.options_2 or options

    local prepared = success_case(g, opts)

    prepare_case({
        dir = prepared.dir,
        roles = roles_2,
        script = script_2,
        options = options_2,
    })
    g.server:exec(function()
        local config = require('config')
        config:reload()
    end)
    g.server:exec(verify_2, verify_args_2)
end

-- Start a server, write a new script/config, reload, run a
-- verification function.
--
-- * opts.roles
-- * opts.script
-- * opts.options
-- * opts.verify
-- * opts.env
--
--   Same as in success_case().
--
-- * opts.roles_2
--
--   A new list of roles to prepare before config:reload().
--
-- * opts.script_2
--
--   A new script to write into the main.lua file before
--   config:reload().
--
-- * opts.options_2
--
--   A new config to use for the config:reload(). It is optional,
--   if not provided opts.options is used instead.
--
-- * opts.exp_err
--
--   An error that config:reload() must raise.
local function reload_failure_case(g, opts)
    local script_2 = opts.script_2
    local roles_2 = opts.roles_2
    local options = assert(opts.options)
    local options_2 = opts.options_2 or options
    local exp_err = assert(opts.exp_err)

    local prepared = success_case(g, opts)

    prepare_case({
        dir = prepared.dir,
        roles = roles_2,
        script = script_2,
        options = options_2,
    })
    t.assert_error_msg_equals(exp_err, g.server.exec, g.server, function()
        local config = require('config')
        config:reload()
    end)
    g.server:exec(function(exp_err)
        local config = require('config')
        local info = config:info()
        t.assert_equals(info.status, 'check_errors')
        t.assert_equals(#info.alerts, 1)
        t.assert_equals(info.alerts[1].type, 'error')
        t.assert(info.alerts[1].timestamp ~= nil)
        t.assert_equals(info.alerts[1].message, exp_err)
    end, {exp_err})
end

return {
    -- Setup a group of tests that are prepended/postpones with
    -- hooks to stop servers between tests and to remove temporary
    -- files after the testing.
    group = group,

    -- Write the given function into a Lua file and execute it.
    --
    -- Ensure that the exit code is zero and there is no
    -- stdout/stderr output.
    --
    -- Use require('myluatest') instead of require('luatest')
    -- inside the test case to get better diagnostics at failure.
    run_as_script = run_as_script,

    -- Start a three instance replicaset with the given config
    -- file.
    --
    -- It assumes specific instance/replicaset/group names and
    -- net.box credentials.
    start_example_replicaset = start_example_replicaset,

    -- Run a single instance and verify some invariants.
    --
    -- All the runs are based on the given simple config,
    -- but the options can be adjusted.
    simple_config = simple_config,
    success_case = success_case,
    failure_case = failure_case,
    reload_success_case = reload_success_case,
    reload_failure_case = reload_failure_case,
}
