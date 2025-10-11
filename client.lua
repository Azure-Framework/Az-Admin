local cachedReports = {}
local menuOpen = false
local debugMode = true
local function dbg(fmt, ...) if debugMode then print(('[AdminMenu][Client] ' .. fmt):format(...)) end end

local function showNotification(message)
    BeginTextCommandThefeedPost("STRING")
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end


local pendingReport = nil
local pendingTimeoutHandle = nil
local PENDING_TIMEOUT_MS = 10000

local PENDING_UPLOAD_TIMEOUT_MS = 20000

local function clearPending()
    pendingReport = nil
    if pendingTimeoutHandle then
        pcall(function() Citizen.ClearTimeout(pendingTimeoutHandle) end)
        pendingTimeoutHandle = nil
    end
end


local function extractBase64AndType(img)
    if not img or img == "" then return nil, nil end
    local prefix = img:match('^data:image/(%w+);base64,')
    if prefix then
        local base64 = img:gsub('^data:image/%w+;base64,', '')
        return base64, prefix
    end
    return img, 'png'
end


local function splitIntoChunks(str, size)
    local t = {}
    local len = #str
    local i = 1
    while i <= len do
        local part = str:sub(i, i + size - 1)
        table.insert(t, part)
        i = i + size
    end
    return t
end



local DEFAULT_CHUNK_SIZE = 18000   
local CHUNK_WAIT_MS = 30           
local BATCH_LIMIT = 12             
local BATCH_EXTRA_WAIT_MS = 80     
local MAX_PARTS = 480              






local function uploadBase64AsChunks(base64, filetype)
    if not pendingReport or not base64 then
        dbg("Client: uploadBase64AsChunks called but no pendingReport/base64")
        return
    end
    filetype = filetype or 'jpg'

    local len = #base64
    if len == 0 then
        TriggerServerEvent('adminmenu:server:submitReport', pendingReport.targetId, pendingReport.reason, pendingReport.reporterName, pendingReport.targetName)
        showNotification("Report submitted (no screenshot).")
        clearPending()
        return
    end

    
    local chunkSize = DEFAULT_CHUNK_SIZE
    local total = math.ceil(len / chunkSize)

    
    if total > MAX_PARTS then
        chunkSize = math.ceil(len / MAX_PARTS)
        total = math.ceil(len / chunkSize)
        dbg("Adjusted chunk size to %d to reduce total parts to %d (len=%d)", chunkSize, total, len)
    end

    
    if total > MAX_PARTS or chunkSize <= 0 then
        dbg("Client: screenshot too large to upload in %d parts (len=%d). Aborting upload and sending report without image.", total, len)
        showNotification("Screenshot too large — report submitted without image.", "error")
        TriggerServerEvent('adminmenu:server:submitReport', pendingReport.targetId, pendingReport.reason, pendingReport.reporterName, pendingReport.targetName)
        clearPending()
        return
    end

    
    pendingReport._createRequested = true

    
    TriggerServerEvent('adminmenu:server:createReportForScreenshot',
        pendingReport.targetId,
        pendingReport.reason,
        pendingReport.reporterName,
        pendingReport.targetName,
        filetype,
        total
    )

    
    pendingReport._chunks = splitIntoChunks(base64, chunkSize)
    pendingReport._totalChunks = total

    dbg("Client: prepared %d chunks (chunkSize=%d) for upload", total, chunkSize)

    
    if pendingTimeoutHandle then
        pcall(function() Citizen.ClearTimeout(pendingTimeoutHandle) end)
        pendingTimeoutHandle = Citizen.SetTimeout(PENDING_UPLOAD_TIMEOUT_MS, function()
            if pendingReport and pendingReport._createRequested then
                dbg("Extended upload timeout reached; sending report without screenshot (fallback) for target=%s", tostring(pendingReport.targetId))
                TriggerServerEvent('adminmenu:server:submitReport', pendingReport.targetId, pendingReport.reason, pendingReport.reporterName, pendingReport.targetName)
                showNotification("Report submitted (no screenshot).")
                clearPending()
            end
        end)
    end
end


RegisterNetEvent('adminmenu:client:reportCreated')
AddEventHandler('adminmenu:client:reportCreated', function(reportId)
    if not pendingReport or not pendingReport._chunks then
        dbg("Client: got reportCreated but have no pending chunks.")
        return
    end

    local parts = pendingReport._chunks
    local total = pendingReport._totalChunks or #parts
    dbg("Client: starting upload for reportId=%s total=%s", tostring(reportId), tostring(total))

    
    if total ~= #parts then
        dbg("Client: note mismatch between expected total (%s) and actual parts (%s)", tostring(total), tostring(#parts))
        total = math.min(total, #parts)
    end

    
    if total > MAX_PARTS then
        dbg("Client: server expected too many parts (%s) — aborting client upload", tostring(total))
        showNotification("Upload aborted (too many chunks).", "error")
        clearPending()
        return
    end

    local sentCount = 0
    for i = 1, total do
        local part = parts[i]
        if not part then
            dbg("Client: missing chunk %s for report %s - stopping upload", tostring(i), tostring(reportId))
            break
        end

        
        local okSend, sendErr = pcall(function()
            TriggerServerEvent('adminmenu:server:uploadScreenshotChunk', reportId, i, total, part)
        end)
        if not okSend then
            dbg("Client: TriggerServerEvent failed for chunk %s: %s", tostring(i), tostring(sendErr))
            Citizen.Wait(100)
        end

        sentCount = sentCount + 1

        
        Citizen.Wait(CHUNK_WAIT_MS)

        if (sentCount % BATCH_LIMIT) == 0 then
            Citizen.Wait(BATCH_EXTRA_WAIT_MS)
        end
    end

    
    pcall(function() TriggerServerEvent('adminmenu:server:finalizeScreenshotUpload', reportId) end)

    showNotification("Report submitted with screenshot (uploading).")
    dbg("Client: finished sending chunks for reportId=%s (sent=%s)", tostring(reportId), tostring(sentCount))
    clearPending()
end)


RegisterNetEvent('adminmenu:client:reportUploadStatus')
AddEventHandler('adminmenu:client:reportUploadStatus', function(reportId, ok, httpStatus, message)
    dbg("Client: upload status for reportId=%s ok=%s http=%s message=%s", tostring(reportId), tostring(ok), tostring(httpStatus), tostring(message))
    if ok then
        showNotification("Report uploaded to Discord (report #" .. tostring(reportId) .. ").")
    else
        showNotification("Report uploaded BUT Discord returned error: " .. tostring(message))
    end
end)


RegisterNetEvent('adminmenu:client:reportScreenshot')
AddEventHandler('adminmenu:client:reportScreenshot', function(reportId, dataUrl)
    
    if cachedReports then
        for i, rep in ipairs(cachedReports) do
            if rep.id == reportId then
                rep.screenshotDataUrl = dataUrl
                
                rep.screenshot = nil
                rep.screenshotFiletype = nil
                break
            end
        end
    end

    
    SendNUIMessage({ action = 'reportScreenshot', id = reportId, image = dataUrl })
end)


RegisterNetEvent('adminmenu:clientPlayerDiscord')
AddEventHandler('adminmenu:clientPlayerDiscord', function(targetId, discordId)
    
    SendNUIMessage({ action = 'playerDiscord', target = targetId, discord = discordId })
end)


local function RequestScreenshotAndSend(reportData)
    pendingReport = reportData

    local tookScreenshot = false
    local ok, hasScreenshotBasic = pcall(function() return exports['screenshot-basic'] ~= nil end)
    if ok and hasScreenshotBasic and exports['screenshot-basic'] and exports['screenshot-basic'].requestScreenshot then
        tookScreenshot = true
        exports['screenshot-basic']:requestScreenshot(function(img)
            if not pendingReport then return end
            if img and img ~= "" then
                local base64, filetype = extractBase64AndType(img)
                dbg("Client: got screenshot, base64 len = %d", #tostring(base64 or ""))
                uploadBase64AsChunks(base64, filetype)
            else
                TriggerServerEvent('adminmenu:server:submitReport', pendingReport.targetId, pendingReport.reason, pendingReport.reporterName, pendingReport.targetName)
                showNotification("Report submitted (no screenshot).")
                clearPending()
            end
        end)
    end

    if not tookScreenshot then
        
        SendNUIMessage({ type = 'capture' })
    end

    
    pendingTimeoutHandle = Citizen.SetTimeout(PENDING_TIMEOUT_MS, function()
        if pendingReport then
            
            if pendingReport._createRequested then
                dbg("Initial screenshot timeout reached but upload was already requested by client; extending wait.")
                if pendingTimeoutHandle then pcall(function() Citizen.ClearTimeout(pendingTimeoutHandle) end) end
                pendingTimeoutHandle = Citizen.SetTimeout(PENDING_UPLOAD_TIMEOUT_MS, function()
                    if pendingReport and pendingReport._createRequested then
                        dbg("Extended upload timeout reached; sending report without screenshot for target=%s", tostring(pendingReport.targetId))
                        TriggerServerEvent('adminmenu:server:submitReport', pendingReport.targetId, pendingReport.reason, pendingReport.reporterName, pendingReport.targetName)
                        showNotification("Report submitted (no screenshot).")
                        clearPending()
                    end
                end)
                return
            end

            dbg("Screenshot upload timed out; sending report without screenshot for target=%s", tostring(pendingReport.targetId))
            TriggerServerEvent('adminmenu:server:submitReport', pendingReport.targetId, pendingReport.reason, pendingReport.reporterName, pendingReport.targetName)
            showNotification("Report submitted (no screenshot).")
            clearPending()
        end
    end)
end

RegisterNUICallback('screenshotCaptured', function(data, cb)
    local img = data and data.image or nil
    if not pendingReport then
        dbg("Received NUI screenshot but no pending report.")
        cb({ ok = false })
        return
    end
    if img and img ~= "" then
        local base64, filetype = extractBase64AndType(img)
        uploadBase64AsChunks(base64, filetype)
        cb({ ok = true })
    else
        TriggerServerEvent('adminmenu:server:submitReport', pendingReport.targetId, pendingReport.reason, pendingReport.reporterName, pendingReport.targetName)
        cb({ ok = true })
        showNotification("Report submitted (no screenshot).")
        clearPending()
    end
end)


RegisterNetEvent('adminmenu:client:newReport')
AddEventHandler('adminmenu:client:newReport', function(report)
    cachedReports = cachedReports or {}
    
    for _, r in ipairs(cachedReports) do
        if r.id == report.id then
            
            SendNUIMessage({ action = 'newReport', report = report })
            showNotification(string.format("🛎 New report #%d from %s against %s", report.id, report.reporterName, report.targetName))
            return
        end
    end
    table.insert(cachedReports, 1, report) 
    SendNUIMessage({ action = 'newReport', report = report })
    showNotification(string.format("🛎 New report #%d from %s against %s", report.id, report.reporterName, report.targetName))
end)

RegisterNetEvent('adminmenu:client:loadReports')
AddEventHandler('adminmenu:client:loadReports', function(reports)
    cachedReports = reports or {}
    SendNUIMessage({ action = 'loadReports', reports = cachedReports })
end)

RegisterNetEvent('adminmenu:client:updateReport')
AddEventHandler('adminmenu:client:updateReport', function(reportId, resolved)
    
    if cachedReports then
        for i, rep in ipairs(cachedReports) do
            if rep.id == reportId then
                rep.resolved = resolved
                break
            end
        end
    end
    SendNUIMessage({ action = 'updateReport', id = reportId, resolved = resolved })
end)

RegisterNetEvent('adminmenu:client:removeReport')
AddEventHandler('adminmenu:client:removeReport', function(reportId)
    
    if cachedReports then
        for i, rep in ipairs(cachedReports) do
            if rep.id == reportId then
                table.remove(cachedReports, i)
                break
            end
        end
    end
    SendNUIMessage({ action = 'removeReport', id = reportId })
end)


RegisterNUICallback('getDepartments', function(_, cb)
    
    cb({ departments = cachedDepartments })

    
    TriggerServerEvent('adminmenu:serverGetDepartments')
end)

RegisterNUICallback('openMenu', function(data, cb)
    TriggerServerEvent('adminmenu:serverGetReports')
    TriggerServerEvent('adminmenu:serverGetDepartments')
    cb({ ok = true })
end)

RegisterNUICallback('getReports', function(_, cb)
    if not cachedReports or #cachedReports == 0 then
        TriggerServerEvent('adminmenu:serverGetReports')
        cb({ ok = true })
        return
    end
    cb({ reports = cachedReports })
end)


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

    local reportObj = {
        targetId = targetId,
        reason = reason,
        reporterName = reporterName,
        targetName = targetName
    }
    RequestScreenshotAndSend(reportObj)
end, false)

RegisterNUICallback('submitReport', function(data, cb)
    local target = tonumber(data.target)
    if not target then
        cb({ ok = false, error = "Invalid target" })
        return
    end

    local reportObj = {
        targetId = target,
        reason = tostring(data.reason or "No reason provided"),
        reporterName = GetPlayerName(PlayerId()),
        targetName = GetPlayerName(GetPlayerFromServerId(target)) or tostring(target)
    }
    RequestScreenshotAndSend(reportObj)
    cb({ ok = true })
    showNotification("Submitting report...")
end)

RegisterNUICallback('resolveReport', function(data, cb)
    TriggerServerEvent('adminmenu:server:resolveReport', data.id)
    cb({ ok = true })
end)
RegisterNUICallback('deleteReport', function(data, cb)
    TriggerServerEvent('adminmenu:server:deleteReport', data.id)
    cb({ ok = true })
end)

RegisterNUICallback('teleportReport', function(data, cb)
    TriggerServerEvent('adminmenu:serverTeleportTo', { target = data.target })
    cb({ ok = true })
end)


local function relay(evt, data, cb)
    TriggerServerEvent('adminmenu:' .. evt, data)
    cb({ ok = true })
end
RegisterNUICallback('createDepartment', function(d, cb) relay('serverCreateDepartment', d, cb) end)
RegisterNUICallback('modifyDepartment', function(d, cb) relay('serverModifyDepartment', d, cb) end)
RegisterNUICallback('assignDepartment', function(d, cb) relay('serverAssignDepartment', d, cb) end)
RegisterNUICallback('removeDepartment', function(d, cb) relay('serverRemoveDepartment', d, cb) end)
RegisterNUICallback('teleportTo', function(d, cb) relay('serverTeleportTo', d, cb) end)
RegisterNUICallback('bring',      function(d, cb) relay('serverBring',      d, cb) end)
RegisterNUICallback('freeze',     function(d, cb) relay('serverToggleFreeze', d, cb) end)
RegisterNUICallback('kick',       function(d, cb) relay('serverKick', d, cb) end)
RegisterNUICallback('ban',        function(d, cb) relay('serverBan', d, cb) end)
RegisterNUICallback('moneyOp',    function(d, cb) relay('serverMoneyOp',    d, cb) end)


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



RegisterNetEvent('adminmenu:loadDepartments')
AddEventHandler('adminmenu:loadDepartments', function(departments)
    cachedDepartments = departments or {}
    SendNUIMessage({ action = 'loadDepartments', departments = cachedDepartments })
    SetNuiFocus(true, true)
end)

RegisterNetEvent('adminmenu:clientReceiveDepartments')
AddEventHandler('adminmenu:clientReceiveDepartments', function(data)
    cachedDepartments = data.departments or {}
    SendNUIMessage({ action = 'loadDepartments', departments = cachedDepartments })
end)


RegisterCommand('adminmenu', function()
    dbg("Command invoked by player")
    TriggerServerEvent('adminmenu:verifyAdmin')
end, false)

RegisterNetEvent('adminmenu:allowOpen')
AddEventHandler('adminmenu:allowOpen', function()
    menuOpen = not menuOpen
    SetNuiFocus(menuOpen, menuOpen)
    SendNUIMessage({ action = 'openMenu' })
    if menuOpen then
        TriggerServerEvent('adminmenu:serverGetDepartments')
        TriggerServerEvent('adminmenu:serverGetReports')
    end
end)

RegisterNUICallback('closeMenu', function(_, cb)
    menuOpen = false
    SetNuiFocus(false, false)
    cb({ ok = true })
end)


RegisterNetEvent('adminmenu:clientTeleportTo')
AddEventHandler('adminmenu:clientTeleportTo', function(targetServerId)
    local playerPed = PlayerPedId()
    local targetIdx = GetPlayerFromServerId(targetServerId)
    if targetIdx ~= -1 then
        local targetPed = GetPlayerPed(targetIdx)
        if DoesEntityExist(targetPed) then
            local x,y,z = table.unpack(GetEntityCoords(targetPed))
            SetEntityCoords(playerPed, x, y, z, false, false, false, true)
        end
    end
end)

RegisterNetEvent('adminmenu:clientForceTeleport')
AddEventHandler('adminmenu:clientForceTeleport', function(coords)
    local playerPed = PlayerPedId()
    if coords.x and coords.y and coords.z then
        SetEntityCoords(playerPed, coords.x, coords.y, coords.z, false, false, false, true)
    end
end)

RegisterNetEvent('adminmenu:clientSetFreeze')
AddEventHandler('adminmenu:clientSetFreeze', function(shouldFreeze)
    local playerPed = PlayerPedId()
    FreezeEntityPosition(playerPed, shouldFreeze)
    if not shouldFreeze then
        SetEntityCollision(playerPed, true, true)
    end
end)


RegisterNUICallback('requestPlayerDiscord', function(data, cb)
    local target = tonumber(data.target)
    if not target then cb({ ok = false }); return end
    TriggerServerEvent('adminmenu:serverRequestPlayerDiscord', target)
    cb({ ok = true })
end)


local function round(num, decimals)
    local mult = 10^(decimals or 3)
    return math.floor(num * mult + 0.5) / mult
end

RegisterCommand("pos3", function()
    local ped = PlayerPedId()
    local x, y, z = table.unpack(GetEntityCoords(ped, true))
    x, y, z = round(x, 3), round(y, 3), round(z, 3)
    local vec3 = string.format("vector3(%.3f, %.3f, %.3f)", x, y, z)
    if lib and lib.setClipboard then lib.setClipboard(vec3) end
    TriggerEvent("chat:addMessage", { args = { "^2[POS3]^7 Copied → " .. vec3 } })
end, false)

RegisterCommand("pos4", function()
    local ped = PlayerPedId()
    local x, y, z = table.unpack(GetEntityCoords(ped, true))
    local h     = GetEntityHeading(ped)
    x, y, z, h  = round(x, 3), round(y, 3), round(z, 3), round(h, 3)
    local vec4 = string.format("vector4(%.3f, %.3f, %.3f, %.3f)", x, y, z, h)
    if lib and lib.setClipboard then lib.setClipboard(vec4) end
    TriggerEvent("chat:addMessage", { args = { "^2[POS4]^7 Copied → " .. vec4 } })
end, false)
