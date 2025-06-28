local menuOpen = false

RegisterCommand('adminmenu', function()
    -- TriggerServerEvent('adminmenu:verifyAdmin')
        TriggerEvent('adminmenu:allowOpen')
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
