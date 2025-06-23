local debugMode = true
local function dbg(fmt, ...) if debugMode then print(('[admin] ' .. fmt):format(...)) end end

local banned = {}
local frozen = {}

RegisterNetEvent('adminmenu:verifyAdmin')
AddEventHandler('adminmenu:verifyAdmin', function()
    local src = source
    exports['Az-Framework']:isAdmin(src, function(isAdmin)
        exports['Az-Framework']:logAdminCommand('adminmenu', src, {}, isAdmin)
        if isAdmin then
            TriggerClientEvent('adminmenu:allowOpen', src)
            dbg("%d is an admin, opening menu", src)
        else
            TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'You are not authorized to use this.' } })
            dbg("%d tried to open menu but is not admin", src)
        end
    end)
end)

-- Kicks
RegisterNetEvent('adminmenu:serverKick')
AddEventHandler('adminmenu:serverKick', function(data)
    DropPlayer(tonumber(data.target), data.reason or "Kicked by admin")
    dbg("Kicked %d", data.target)
end)

-- Bans
RegisterNetEvent('adminmenu:serverBan')
AddEventHandler('adminmenu:serverBan', function(data)
    banned[tonumber(data.target)] = true
    DropPlayer(tonumber(data.target), "Banned by admin")
    dbg("Banned %d", data.target)
end)

AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
    if banned[source] then
        deferrals.done("You are banned from this server.")
    else
        deferrals.done()
    end
end)

-- Teleports
RegisterNetEvent('adminmenu:serverTeleportTo')
AddEventHandler('adminmenu:serverTeleportTo', function(data)
    TriggerClientEvent('adminmenu:clientTeleportTo', source, data.target)
    dbg("Admin %d teleported to %d", source, data.target)
end)

RegisterNetEvent('adminmenu:serverBring')
AddEventHandler('adminmenu:serverBring', function(data)
    local coords = GetEntityCoords(GetPlayerPed(source))
    TriggerClientEvent('adminmenu:clientForceTeleport', data.target, { x = coords.x, y = coords.y, z = coords.z })
    dbg("Brought %d to %d", data.target, source)
end)

-- Freezing
RegisterNetEvent('adminmenu:serverToggleFreeze')
AddEventHandler('adminmenu:serverToggleFreeze', function(data)
    local tgt = tonumber(data.target)
    frozen[tgt] = not frozen[tgt]
    TriggerClientEvent('adminmenu:clientSetFreeze', tgt, frozen[tgt])
    dbg("%s %d", frozen[tgt] and "Froze" or "Unfroze", tgt)
end)

-- Money Ops
RegisterNetEvent('adminmenu:serverMoneyOp')
AddEventHandler('adminmenu:serverMoneyOp', function(data)
    local op = data.op
    local tgt = tonumber(data.target)
    local amt = tonumber(data.amount) or 0
    local extra = tonumber(data.extra) or 0

    if op == "add" then exports['Az-Framework']:addMoney(tgt, amt)
    elseif op == "deduct" then exports['Az-Framework']:deductMoney(tgt, amt)
    elseif op == "modify" then exports['Az-Framework']:modifyMoney(tgt, amt)
    elseif op == "deposit" then exports['Az-Framework']:depositMoney(tgt, amt)
    elseif op == "withdraw" then exports['Az-Framework']:withdrawMoney(tgt, amt)
    elseif op == "transfer" then exports['Az-Framework']:transferMoney(tgt, extra, amt)
    elseif op == "daily" then exports['Az-Framework']:claimDailyReward(tgt, amt)
    else
        dbg("Invalid moneyOp %s on %d", op, tgt)
    end

    dbg("Money op '%s' on %d: %d", op, tgt, amt)
end)

RegisterNetEvent('adminmenu:serverCreateDepartment')
AddEventHandler('adminmenu:serverCreateDepartment', function(data)
    local src = source
    MySQL.Async.execute('INSERT IGNORE INTO econ_departments (discordid, department, paycheck) VALUES (?, ?, ?)', {
        data.discordid or "global",
        data.department,
        tonumber(data.paycheck) or 0
    }, function(rowsChanged)
        dbg("Created department %s", data.department)
    end)
end)

RegisterNetEvent('adminmenu:serverModifyDepartment')
AddEventHandler('adminmenu:serverModifyDepartment', function(data)
    local src = source
    MySQL.Async.execute('UPDATE econ_departments SET paycheck = ? WHERE department = ?', {
        tonumber(data.paycheck) or 0,
        data.department
    }, function(rowsChanged)
        dbg("Modified department %s", data.department)
    end)
end)

RegisterNetEvent('adminmenu:serverAssignDepartment')
AddEventHandler('adminmenu:serverAssignDepartment', function(data)
    local src = source
    MySQL.Async.execute('UPDATE econ_departments SET department = ? WHERE discordid = ?', {
        data.department,
        data.discordid
    }, function(rowsChanged)
        dbg("Assigned %s to %s", data.discordid, data.department)
    end)
end)

RegisterNetEvent('adminmenu:serverGetDepartments')
AddEventHandler('adminmenu:serverGetDepartments', function()
    local src = source
    MySQL.Async.fetchAll('SELECT * FROM econ_departments', {}, function(departments)
        -- send straight back to the NUI
        TriggerClientEvent('adminmenu:loadDepartments', src, departments)
    end)
end)

RegisterNetEvent('adminmenu:serverRemoveDepartment')
AddEventHandler('adminmenu:serverRemoveDepartment', function(data)
    local src = source
    MySQL.Async.execute(
        'DELETE FROM econ_departments WHERE discordid = ? AND department = ?',
        { 'global', data.department },
        function(rowsChanged)
            dbg("Removed department %s", data.department)
        end
    )
end)






-- ============================================
-- ============================================
-- Helper Commands.
-- ============================================
-- ============================================


-- Teleport admin to arbitrary coords: /goto x y z [heading]
RegisterCommand('goto', function(source, args, rawCommand)
    -- first verify they're an admin
    exports['Az-Framework']:isAdmin(source, function(isAdmin)
        if not isAdmin then
            TriggerClientEvent('chat:addMessage', source, {
                args = { '[AdminMenu]', 'You are not authorized to use this command.' }
            })
            return
        end

        -- need at least 3 args: x, y, z
        if #args < 3 then
            TriggerClientEvent('chat:addMessage', source, {
                args = { '[AdminMenu]', 'Usage: /goto <x> <y> <z> [heading]' }
            })
            return
        end

        -- parse coordinates
        local x = tonumber(args[1])
        local y = tonumber(args[2])
        local z = tonumber(args[3])
        local h = tonumber(args[4]) or 0.0

        if not x or not y or not z then
            TriggerClientEvent('chat:addMessage', source, {
                args = { '[AdminMenu]', 'Invalid coordinates. All of x, y, z must be numbers.' }
            })
            return
        end

        -- send to client to teleport
        TriggerClientEvent('adminmenu:clientForceTeleport', source, {
            x = x, y = y, z = z, h = h
        })

        dbg("Admin %d used /goto to teleport to (%.2f, %.2f, %.2f, heading=%.2f)", source, x, y, z, h)
    end)
end, false)
