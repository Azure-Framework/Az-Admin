local menuOpen = false

RegisterCommand('adminmenu', function()
    TriggerServerEvent('adminmenu:verifyAdmin')
end, false)

RegisterNetEvent('adminmenu:allowOpen')
AddEventHandler('adminmenu:allowOpen', function()
    menuOpen = not menuOpen
    SetNuiFocus(menuOpen, menuOpen)
    SendNUIMessage({ action = 'openMenu' })
    if menuOpen then
        -- load existing departments as soon as the menu opens
        TriggerServerEvent('adminmenu:serverGetDepartments')
    end
    SendNUIMessage({ action = 'openMenu' })
end)

RegisterNUICallback('closeMenu', function(_, cb)
    menuOpen = false
    SetNuiFocus(false, false)
    cb({ ok = true })
end)

RegisterNUICallback('getPlayers', function(_, cb)
    local plys = {}
    for _, idx in ipairs(GetActivePlayers()) do
        local sid  = GetPlayerServerId(idx)
        local name = GetPlayerName(idx) or "Unknown"
        table.insert(plys, { id = sid, name = name })
    end
    cb({ players = plys })
end)
RegisterNetEvent('adminmenu:loadDepartments')
AddEventHandler('adminmenu:loadDepartments', function(departments)
    SendNUIMessage({
        action = 'loadDepartments',
        departments = departments
    })
    SetNuiFocus(true, true)
end)
-- when the HTML/JS does fetch('/getDepartments'), forward it to the server
RegisterNUICallback('getDepartments', function(_, cb)
    -- ask server to read from MySQL
    TriggerServerEvent('adminmenu:serverGetDepartments')
    -- immediately ack (the actual data arrives via adminmenu:clientReceiveDepartments)
    cb({ ok = true })
end)


-- relay to server
local function relay(evt, data, cb)
    TriggerServerEvent('adminmenu:' .. evt, data)
    cb({ ok = true })
end

-- Admin actions
RegisterNUICallback('kick',       function(d, cb) relay('serverKick',       d, cb) end)
RegisterNUICallback('ban',        function(d, cb) relay('serverBan',        d, cb) end)
RegisterNUICallback('teleportTo', function(d, cb) relay('serverTeleportTo', d, cb) end)
RegisterNUICallback('bring',      function(d, cb) relay('serverBring',      d, cb) end)
RegisterNUICallback('freeze',     function(d, cb) relay('serverToggleFreeze', d, cb) end)
RegisterNUICallback('moneyOp',    function(d, cb) relay('serverMoneyOp',    d, cb) end)

-- Department management
RegisterNUICallback('createDepartment', function(d, cb) relay('serverCreateDepartment', d, cb) end)
RegisterNUICallback('modifyDepartment', function(d, cb) relay('serverModifyDepartment', d, cb) end)
RegisterNUICallback('assignDepartment', function(d, cb) relay('serverAssignDepartment', d, cb) end)

RegisterNetEvent('adminmenu:clientTeleportTo')
AddEventHandler('adminmenu:clientTeleportTo', function(targetId)
    local me = PlayerPedId()
    local tp = GetPlayerPed(GetPlayerFromServerId(targetId))
    if tp ~= 0 then
        local x, y, z = table.unpack(GetEntityCoords(tp))
        SetEntityCoords(me, x, y, z + 1.0, false, false, false, true)
    end
end)

RegisterNetEvent('adminmenu:clientForceTeleport')
AddEventHandler('adminmenu:clientForceTeleport', function(coords)
    SetEntityCoords(PlayerPedId(), coords.x, coords.y, coords.z + 1.0, false, false, false, true)
end)

RegisterNetEvent('adminmenu:clientSetFreeze')
AddEventHandler('adminmenu:clientSetFreeze', function(state)
    FreezeEntityPosition(PlayerPedId(), state)
end)

RegisterNetEvent('adminmenu:clientReceiveDepartments')
AddEventHandler('adminmenu:clientReceiveDepartments', function(data)
    -- data.departments is an array of { discordid, department, paycheck }
    SendNUIMessage({
        action      = 'loadDepartments',
        departments = data.departments
    })
end)
