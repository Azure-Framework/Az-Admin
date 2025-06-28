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
    local src = source
    local op  = data.op
    local tgt = tonumber(data.target)
    local amt = tonumber(data.amount) or 0
    local extra = tonumber(data.extra) or 0  -- only used for transfer

    -- 1) Verify this player is an admin
    exports['Az-Framework']:isAdmin(src, function(isAdmin)
        if not isAdmin then
            TriggerClientEvent('chat:addMessage', src, {
                args = { '[AdminMenu]', 'You are not authorized to use that.' }
            })
            return
        end

        -- 2) Basic validation
        if not tgt or tgt <= 0 then
            TriggerClientEvent('chat:addMessage', src, {
                args = { '[AdminMenu]', 'Invalid target player ID.' }
            })
            return
        end

        if amt <= 0 and op ~= 'modify' then
            TriggerClientEvent('chat:addMessage', src, {
                args = { '[AdminMenu]', 'Amount must be greater than zero.' }
            })
            return
        end

        -- 3) Dispatch the correct Az‑Framework call
        if op == "add" then
            exports['Az-Framework']:addMoney(tgt, amt)

        elseif op == "deduct" then
            exports['Az-Framework']:deductMoney(tgt, amt)

        elseif op == "modify" then
            -- modify to exact balance
            exports['Az-Framework']:modifyMoney(tgt, amt)

        elseif op == "deposit" then
            exports['Az-Framework']:depositMoney(tgt, amt)

        elseif op == "withdraw" then
            exports['Az-Framework']:withdrawMoney(tgt, amt)

        elseif op == "transfer" then
            -- extra = recipient, amt = amount
            if extra <= 0 then
                TriggerClientEvent('chat:addMessage', src, {
                    args = { '[AdminMenu]', 'You must specify a valid recipient ID for transfer.' }
                })
                return
            end
            exports['Az-Framework']:transferMoney(tgt, extra, amt)

        elseif op == "daily" then
            exports['Az-Framework']:claimDailyReward(tgt, amt)

        else
            TriggerClientEvent('chat:addMessage', src, {
                args = { '[AdminMenu]', 'Unknown money operation: ' .. tostring(op) }
            })
            return
        end

        -- 4) Notify admin & (if appropriate) target
        TriggerClientEvent('chat:addMessage', src, {
            args = {
                '[AdminMenu]',
                ('You ran %s $%d for player ID %d.'):format(op, amt, (op == 'transfer' and extra or tgt))
            }
        })
        if op ~= 'modify' then
            -- let the target know something happened to their money
            TriggerClientEvent('chat:addMessage', tgt, {
                args = {
                    '[Bank]',
                    ('Your balance was %s by an admin: %s $%d'):format(
                        (op == 'deduct' or op == 'withdraw') and 'decreased' or 'increased',
                        op, amt
                    )
                }
            })
        end
    end)
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












-- Test: Get active character ID
RegisterCommand("testchar", function(source, args, raw)
    if source == 0 then
        print("^1[testchar]^7 Cannot run from console.")
        return
    end

    local charID = exports['Az-Framework']:GetPlayerCharacter(source)
    if not charID then
        TriggerClientEvent("chat:addMessage", source, { args = {"^1SYSTEM","No character selected."} })
    else
        TriggerClientEvent("chat:addMessage", source, { args = {"^2SYSTEM","Active charID → "..charID} })
    end
end, false)

-- Test: Get active character name
RegisterCommand("testcharname", function(source, args, raw)
    if source == 0 then
        print("^1[testcharname]^7 Cannot run from console.")
        return
    end

    exports['Az-Framework']:GetPlayerCharacterName(source, function(err, fullName)
        if err then
            TriggerClientEvent("chat:addMessage", source, { args = {"^1SYSTEM","Error fetching name: "..err} })
        else
            TriggerClientEvent("chat:addMessage", source, { args = {"^2SYSTEM","Character name → "..fullName} })
        end
    end)
end, false)

-- Test: Get cash & bank balances
RegisterCommand("testmoney", function(source, args, raw)
    if source == 0 then
        print("^1[testmoney]^7 Cannot run from console.")
        return
    end

    exports['Az-Framework']:GetPlayerMoney(source, function(err, balances)
        if err then
            TriggerClientEvent("chat:addMessage", source, { args = {"^1SYSTEM","Error fetching money: "..err} })
        else
            TriggerClientEvent("chat:addMessage", source, {
                args = {
                    "^2SYSTEM",
                    ("Cash: $%d  |  Bank: $%d"):format(balances.cash, balances.bank)
                }
            })
        end
    end)
end, false)
