local function showNotification(message)
    BeginTextCommandThefeedPost("STRING")
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end

-- Forward server reports to NUI
RegisterNetEvent('adminmenu:client:newReport')
AddEventHandler('adminmenu:client:newReport', function(report)
    -- forward to NUI (so when panel is open you still see it in the web UI)
    SendNUIMessage({ action = 'newReport', report = report })

    -- always fire a native text‑feed notification so admins get alerted
    showNotification(
      string.format(
        "🛎 New report #%d from %s against %s",
        report.id,
        report.reporterName,
        report.targetName
      )
    )
end)


RegisterNetEvent('adminmenu:client:loadReports')
AddEventHandler('adminmenu:client:loadReports', function(reports)
    SendNUIMessage({ action = 'loadReports', reports = reports })
end)

RegisterNetEvent('adminmenu:client:updateReport')
AddEventHandler('adminmenu:client:updateReport', function(reportId, resolved)
    SendNUIMessage({ action = 'updateReport', id = reportId, resolved = resolved })
end)

RegisterNetEvent('adminmenu:client:removeReport')
AddEventHandler('adminmenu:client:removeReport', function(reportId)
    SendNUIMessage({ action = 'removeReport', id = reportId })
end)

-- When the menu opens
RegisterNUICallback('openMenu', function(data, cb)
    TriggerServerEvent('adminmenu:server:adminOpenedMenu')
    cb({ ok = true })
end)

-- (Optional) legacy getReports callback
RegisterNUICallback('getReports', function(data, cb)
    cb({ reports = reports })
end)

-- In‑UI “/report” command
RegisterCommand('report', function(source, args)
    if #args < 2 then
        showNotification("Usage: /report [playerID] [reason]")
        return
    end
    local targetId = tonumber(args[1])
    if not targetId then
        showNotification("Invalid player ID")
        return
    end
    local reason = table.concat(args, " ", 2)
    local reporterName = GetPlayerName(PlayerId())
    local targetName   = GetPlayerName(GetPlayerFromServerId(targetId))
    if not targetName then
        showNotification("Player not found")
        return
    end
    TriggerServerEvent('adminmenu:server:submitReport', targetId, reason, reporterName, targetName)
    showNotification("Report submitted against " .. targetName)
end, false)

-- Submit from NUI
RegisterNUICallback('submitReport', function(data, cb)
    TriggerServerEvent(
      'adminmenu:server:submitReport',
      data.target, data.reason,
      GetPlayerName(PlayerId()),
      GetPlayerName(GetPlayerFromServerId(data.target))
    )
    cb({ ok = true })
    showNotification("Report submitted successfully")
end)

-- Resolve a report
RegisterNUICallback('resolveReport', function(data, cb)
    TriggerServerEvent('adminmenu:server:resolveReport', data.id)
    cb({ ok = true })
end)

-- Delete a report
RegisterNUICallback('deleteReport', function(data, cb)
    TriggerServerEvent('adminmenu:server:deleteReport', data.id)
    cb({ ok = true })
end)

-- Teleport from report
RegisterNUICallback('teleportReport', function(data, cb)
    TriggerServerEvent('adminmenu:serverTeleportTo', { target = data.target })
    cb({ ok = true })
end)
local menuOpen = false
local debugMode = true
local function dbg(fmt, ...) if debugMode then print(('[AdminMenu][Client] ' .. fmt):format(...)) end end

-- /adminmenu command
RegisterCommand('adminmenu', function()
    local src = PlayerId()
    dbg("Command invoked by playerId=%d", src)
    TriggerServerEvent('adminmenu:verifyAdmin')
end, false)

-- Server says “you’re admin → open”
RegisterNetEvent('adminmenu:allowOpen')
AddEventHandler('adminmenu:allowOpen', function()
    menuOpen = not menuOpen
    SetNuiFocus(menuOpen, menuOpen)
    SendNUIMessage({ action = 'openMenu' })
    if menuOpen then
        TriggerServerEvent('adminmenu:serverGetDepartments')
    end
end)

-- Close NUI
RegisterNUICallback('closeMenu', function(_, cb)
    menuOpen = false
    SetNuiFocus(false, false)
    cb({ ok = true })
end)

-- Get players for UI
RegisterNUICallback('getPlayers', function(_, cb)
    local plys = {}
    for _, idx in ipairs(GetActivePlayers()) do
        table.insert(plys, {
            id   = GetPlayerServerId(idx),
            name = GetPlayerName(idx) or "Unknown"
        })
    end
    cb({ players = plys })
end)

-- Load departments into UI
RegisterNetEvent('adminmenu:loadDepartments')
AddEventHandler('adminmenu:loadDepartments', function(departments)
    SendNUIMessage({ action = 'loadDepartments', departments = departments })
    SetNuiFocus(true, true)
end)

-- Fetch departments NUI callback
RegisterNUICallback('getDepartments', function(_, cb)
    TriggerServerEvent('adminmenu:serverGetDepartments')
    cb({ ok = true })
end)

-- Create, modify, assign departments
local function relay(evt, data, cb)
    TriggerServerEvent('adminmenu:' .. evt, data)
    cb({ ok = true })
end

RegisterNUICallback('createDepartment', function(d, cb) relay('serverCreateDepartment', d, cb) end)
RegisterNUICallback('modifyDepartment', function(d, cb) relay('serverModifyDepartment', d, cb) end)
RegisterNUICallback('assignDepartment', function(d, cb) relay('serverAssignDepartment', d, cb) end)
-- **Remove Department**
RegisterNUICallback('removeDepartment', function(d, cb) relay('serverRemoveDepartment', d, cb) end)

-- Teleport, bring, freeze, money ops, etc.
RegisterNUICallback('teleportTo', function(d, cb) relay('serverTeleportTo', d, cb) end)
RegisterNUICallback('bring',      function(d, cb) relay('serverBring',      d, cb) end)
RegisterNUICallback('freeze',     function(d, cb) relay('serverToggleFreeze', d, cb) end)
RegisterNUICallback('moneyOp',    function(d, cb) relay('serverMoneyOp',    d, cb) end)

-- When server pushes departments back
RegisterNetEvent('adminmenu:clientReceiveDepartments')
AddEventHandler('adminmenu:clientReceiveDepartments', function(data)
  SendNUIMessage({ action = 'loadDepartments', departments = data.departments })
end)



-- Teleport _you_ (admin) to the target player’s position
RegisterNetEvent('adminmenu:clientTeleportTo')
AddEventHandler('adminmenu:clientTeleportTo', function(targetServerId)
    local playerPed = PlayerPedId()
    -- get the ped of the target by server ID
    local targetIdx = GetPlayerFromServerId(targetServerId)
    if targetIdx ~= -1 then
        local targetPed = GetPlayerPed(targetIdx)
        if DoesEntityExist(targetPed) then
            local x,y,z = table.unpack(GetEntityCoords(targetPed))
            SetEntityCoords(playerPed, x, y, z, false, false, false, true)
            -- optional: restore heading
        end
    end
end)

-- Bring the target player to _you_
RegisterNetEvent('adminmenu:clientForceTeleport')
AddEventHandler('adminmenu:clientForceTeleport', function(coords)
    local playerPed = PlayerPedId()
    if coords.x and coords.y and coords.z then
        SetEntityCoords(playerPed, coords.x, coords.y, coords.z, false, false, false, true)
    end
end)

-- Freeze or unfreeze a player
RegisterNetEvent('adminmenu:clientSetFreeze')
AddEventHandler('adminmenu:clientSetFreeze', function(shouldFreeze)
    local playerPed = PlayerPedId()
    FreezeEntityPosition(playerPed, shouldFreeze)
    if not shouldFreeze then
        -- ensure collision is re-enabled so you don’t end up floating
        SetEntityCollision(playerPed, true, true)
    end
end)

-- Round a number to n decimal places
local function round(num, decimals)
    local mult = 10^(decimals or 3)
    return math.floor(num * mult + 0.5) / mult
end

-- /pos3: copy vector3(x, y, z)
RegisterCommand("pos3", function()
    local ped = PlayerPedId()
    local x, y, z = table.unpack(GetEntityCoords(ped, true))
    x, y, z = round(x, 3), round(y, 3), round(z, 3)
    -- note: use \t\n for new lines if you ever need them
    local vec3 = string.format("vector3(%.3f, %.3f, %.3f)", x, y, z)
    lib.setClipboard(vec3)
    TriggerEvent("chat:addMessage", {
        args = { "^2[POS3]^7 Copied → " .. vec3 }
    })
end, false)

-- /pos4: copy vector4(x, y, z, heading)
RegisterCommand("pos4", function()
    local ped = PlayerPedId()
    local x, y, z = table.unpack(GetEntityCoords(ped, true))
    local h     = GetEntityHeading(ped)
    x, y, z, h  = round(x, 3), round(y, 3), round(z, 3), round(h, 3)
    local vec4 = string.format("vector4(%.3f, %.3f, %.3f, %.3f)", x, y, z, h)
    lib.setClipboard(vec4)
    TriggerEvent("chat:addMessage", {
        args = { "^2[POS4]^7 Copied → " .. vec4 }
    })
end, false)
