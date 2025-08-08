local reports = {}
local reportIdCounter = 1

-- Submit a new report
RegisterNetEvent('adminmenu:server:submitReport')
AddEventHandler('adminmenu:server:submitReport', function(targetId, reason, reporterName, targetName)
    local src = source
    local time = os.date('%Y-%m-%d %H:%M:%S')
    
    local report = {
        id = reportIdCounter,
        reporterId = src,
        reporterName = reporterName,
        targetId = targetId,
        targetName = targetName,
        reason = reason,
        time = time,
        resolved = false
    }
    
    reports[reportIdCounter] = report
    reportIdCounter = reportIdCounter + 1
    
    -- Notify all admins
    for _, playerId in ipairs(GetPlayers()) do
        if IsPlayerAdmin(playerId) then
            TriggerClientEvent('adminmenu:client:newReport', playerId, report)
        end
    end
    
    print(('[REPORT] %s (ID: %s) reported %s (ID: %s) for: %s'):format(
        reporterName, src, targetName, targetId, reason))
end)


-- Resolve a report
RegisterNetEvent('adminmenu:server:resolveReport')
AddEventHandler('adminmenu:server:resolveReport', function(reportId)
    if reports[reportId] then
        reports[reportId].resolved = true
        TriggerClientEvent('adminmenu:client:updateReport', -1, reportId, true)
    end
end)

-- Delete a report
RegisterNetEvent('adminmenu:server:deleteReport')
AddEventHandler('adminmenu:server:deleteReport', function(reportId)
    if reports[reportId] then
        reports[reportId] = nil
        TriggerClientEvent('adminmenu:client:removeReport', -1, reportId)
    end
end)

-- Check if player is admin (you'll need to implement your own logic here)
function IsPlayerAdmin(playerId)
    -- This should be replaced with your framework's admin check
    -- For example, using exports['Az-Framework']:isAdmin(playerId, callback)
    return true -- Placeholder
end

-- Get reports for admin when they open the menu (This handler might become redundant
-- if you rely solely on the NUI callback for initial load via fetchReports())
RegisterNetEvent('adminmenu:server:adminOpenedMenu')
AddEventHandler('adminmenu:server:adminOpenedMenu', function()
    local src = source
    TriggerClientEvent('adminmenu:client:loadReports', src, reports)
end)

local debugMode = true
local function dbg(fmt, ...) if debugMode then print(('[admin] ' .. fmt):format(...)) end end

local banned = {}
local frozen = {}
RegisterNetEvent('adminmenu:verifyAdmin')
AddEventHandler('adminmenu:verifyAdmin', function()
    local src = source
    print(("[AdminMenu] Event fired, source = %s"):format(tostring(src)))

    -- this flag will let us suppress the warning once we get a reply
    local gotResponse = false

    -- Kick off admin check
    print(("[AdminMenu] Calling Az-Framework:isAdmin for %s"):format(src))
    exports['Az-Framework']:isAdmin(src, function(isAdmin)
        gotResponse = true           -- <- mark that we did get a callback
        print(("[AdminMenu] isAdmin callback invoked for %s, returned = %s"):format(src, tostring(isAdmin)))

        -- Log the command attempt
        exports['Az-Framework']:logAdminCommand('adminmenu', src, {}, isAdmin)
        print(("[AdminMenu] logAdminCommand done for %s"):format(src))

        if isAdmin then
            print(string.format("[AdminMenu] %d is an admin → TriggerClientEvent('adminmenu:allowOpen')", src))
            TriggerClientEvent('adminmenu:allowOpen', src)
        else
            print(string.format("[AdminMenu] %d is NOT an admin → sending chat message", src))
            TriggerClientEvent('chat:addMessage', src, {
                args = { '[AdminMenu]', 'You are not authorized to use this.' }
            })
        end
    end)

    -- Failsafe: if your callback never fires, you’ll see this after 5 seconds
    Citizen.SetTimeout(5000, function()
        if not gotResponse then    -- only warn if we still haven’t heard back
            print(("[AdminMenu] WARNING: No response from isAdmin callback after 5s for %s"):format(src))
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

        -- now fetch the _new_ list and tell the client to reload
        MySQL.Async.fetchAll(
          'SELECT * FROM econ_departments',
          {},
          function(departments)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', src, { departments = departments })
        end)
      end
    )
end)

RegisterNetEvent('adminmenu:server:adminOpenedMenu')
 AddEventHandler('adminmenu:server:adminOpenedMenu', function()
     local src = source

    TriggerClientEvent('adminmenu:clientLoadReports', src, { reports = reports })
     -- you can still trigger departments here if you like
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
