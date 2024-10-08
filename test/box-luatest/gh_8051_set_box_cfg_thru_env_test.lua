local server = require('luatest.server')
local treegen = require('luatest.treegen')
local it = require('test.interactive_tarantool')

local t = require('luatest')
local g = t.group()

g.before_each(function(g)
    g.dir = treegen.prepare_directory({}, {})
end)

g.after_each(function(g)
    if g.child ~= nil then
        g.child:close()
    end

    if g.server ~= nil then
       g.server:stop()
   end
end)

g.test_json_table_curly_bracket = function()
    local env = {["TT_METRICS"] = '{"labels":{"alias":"gh_8051"},' ..
                                  '"include":"all","exclude":["vinyl"]}'}

    g.server = server:new{alias='json_table_curly_bracket', env=env}
    g.server:start()

    t.assert_equals(g.server:get_box_cfg().metrics.labels.alias, 'gh_8051')
end

g.test_json_table_square_bracket = function(g)
    g.child = it.new({
        env = {
            TT_LISTEN = '["localhost:0"]',
        },
    })

    local command = ('box.cfg({work_dir = %q})'):format(g.dir)
    g.child:roundtrip(command)

    g.child:roundtrip('box.cfg.listen', {'localhost:0'})
end

g.test_plain_table = function(g)
    local env = {["TT_LOG_MODULES"] = 'aaa=info,bbb=error'}

    g.server = server:new{alias='plain_table', env=env}
    g.server:start()

    t.assert_equals(g.server:get_box_cfg().log_modules,
                    {['aaa'] = 'info', ['bbb'] = 'error'})
end

g.test_format_error = function(g)
    g.child = it.new({
        env = {
            TT_LOG_MODULES = 'aaa=info,bbb',
        },
    })

    local command = ('box.cfg({work_dir = %q})'):format(g.dir)
    local exp_err = 'in `key=value` or `value` format'
    t.assert_error_msg_contains(exp_err, g.child.roundtrip, g.child, command)
end

g.test_format_error_empty_key = function()
    g.child = it.new({
        env = {
            TT_LOG_MODULES = 'aaa=info,=error',
        },
    })

    local command = ('box.cfg({work_dir = %q})'):format(g.dir)
    local exp_err = '`key` must not be empty'
    t.assert_error_msg_contains(exp_err, g.child.roundtrip, g.child, command)
end
