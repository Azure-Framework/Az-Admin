-- server.lua (include requester in player list)
local json = json or (require and require('json'))

Config = Config or {}
Config.ReportWebhook = Config.ReportWebhook or ""
Config.EmbedColor    = Config.EmbedColor or 3066993
Config.WebhookName   = Config.WebhookName or "Server Reports"
Config.WebhookAvatar = Config.WebhookAvatar or ""
local recentMoneyOps = {} -- [targetId] = timestamp
local MONEY_OP_COOLDOWN_MS = 1500 -- per-target throttle
local MONEY_AMOUNT_LIMIT = 10000000 -- maximum allowed absolute amount for ops (tweak this)

local resourceName = GetCurrentResourceName() or "resource"
local reportsFile = "reports.json"

local reports = {}
local reportIdCounter = 1
local departments = {}
local screenshotBuffers = {}

local function logf(fmt, ...) print(("[admin] " .. (fmt or "%s")):format(...)) end

-- helper: fetch discord id for a server id
local function getDiscordForServerId(sid)
    if not sid then return nil end
    local ids = GetPlayerIdentifiers(sid)
    if not ids then return nil end
    for _, ident in ipairs(ids) do
        if tostring(ident):sub(1,8) == "discord:" then
            return tostring(ident):sub(9)
        end
    end
    return nil
end

-- candidate paths / file helpers (kept minimal for brevity)
local SEP = package.config and package.config:sub(1,1) or '/'
local function normalizePath(p)
    if not p then return p end
    if SEP == '/' then p = p:gsub('\\','/') else p = p:gsub('/','\\') end
    if SEP == '/' then p = p:gsub('/+','/') else p = p:gsub('\\+','\\') end
    return p
end
local function getResourceAbsolutePath()
    if GetResourcePath and type(GetResourcePath) == "function" then
        local base = GetResourcePath(resourceName)
        if base and base ~= "" then return normalizePath(base) end
    end
    return nil
end
local function candidatePaths()
    local paths = {}
    local resAbs = getResourceAbsolutePath()
    if resAbs then
        table.insert(paths, (resAbs .. "/" .. reportsFile))
        table.insert(paths, (resAbs .. "/data/" .. reportsFile))
    end
    table.insert(paths, "./" .. reportsFile)
    table.insert(paths, "./" .. resourceName .. "/" .. reportsFile)
    table.insert(paths, "./resources/" .. resourceName .. "/" .. reportsFile)
    table.insert(paths, "./" .. resourceName .. "/data/" .. reportsFile)
    table.insert(paths, "./data/" .. reportsFile)
    return paths
end

-- load/save reports (kept from original)
local function tryReadFile(path)
    if not path then return nil, "invalid-path" end
    local np = normalizePath(path)
    local f, err = io.open(np, "r")
    if not f then return nil, tostring(err) end
    local content = f:read("*a")
    f:close()
    return content
end
local function tryWriteFile(path, data)
    if not path then return false, "invalid-path" end
    local np = normalizePath(path)
    local ok, err = pcall(function()
        local f = io.open(np, "w")
        if not f then error("open-failed") end
        f:write(data)
        f:close()
    end)
    if not ok then return false, tostring(err) end
    return true
end

local function loadReportsFromFile()
    local paths = candidatePaths()
    logf("Looking for reports.json in %d candidate path(s).", #paths)
    for _, p in ipairs(paths) do
        local content, err = tryReadFile(p)
        if content then
            local ok, decoded = pcall(function() return json.decode(content) end)
            if ok and type(decoded) == "table" then
                reports = {}
                reportIdCounter = 1
                for _, rep in ipairs(decoded) do
                    rep.id = tonumber(rep.id) or rep.id
                    reports[rep.id] = rep
                    if rep.id and type(rep.id) == 'number' then
                        reportIdCounter = math.max(reportIdCounter, rep.id + 1)
                    end
                end
                logf("Loaded %d reports from %s — next id = %d", #decoded, p, reportIdCounter)
                return
            end
        end
    end
    logf("%s not found in resource paths; starting with empty reports", reportsFile)
end

local function saveReportsToFile()
    local arr = {}
    for id, r in pairs(reports) do table.insert(arr, r) end
    local ok, encoded = pcall(function() return json.encode(arr) end)
    if not ok then
        logf("Failed to encode reports to JSON: %s", tostring(encoded))
        return
    end
    for _, p in ipairs(candidatePaths()) do
        local written, err = tryWriteFile(p, encoded)
        if written then
            logf("Saved %d reports to %s", #arr, p)
            return
        end
    end
    logf("ERROR: Could not write reports.json to resource paths.")
end

-- screenshot buffer cleanup
local function cleanupScreenshotBuffer(reportId) screenshotBuffers[reportId] = nil end
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30 * 1000)
        local now = os.time()
        for id, buf in pairs(screenshotBuffers) do
            if buf.createdAt and now - buf.createdAt > 120 then
                logf("Cleaning up stale screenshot buffer for report %s (age=%ds)", tostring(id), now - buf.createdAt)
                cleanupScreenshotBuffer(id)
            end
        end
    end
end)

-- SendDiscordReport (kept)
local function SendDiscordReport(report)
    if not Config.ReportWebhook or Config.ReportWebhook == "" then
        logf("Report webhook not configured; skipping Discord post.")
        return
    end
    local embed = {
        {
            title = "New Player Report",
            color = Config.EmbedColor,
            fields = {
                { name = "Report ID", value = tostring(report.id or "N/A"), inline = true },
                { name = "Time", value = tostring(report.time or "N/A"), inline = true },
                { name = "Reporter", value = (report.reporterName or ("ID "..tostring(report.reporterId or "N/A"))), inline = true },
                { name = "Reporter Server ID", value = tostring(report.reporterId or "N/A"), inline = true },
                { name = "Target", value = (report.targetName or ("ID "..tostring(report.targetId or "N/A"))), inline = true },
                { name = "Target Server ID", value = tostring(report.targetId or "N/A"), inline = true },
                { name = "Reason", value = tostring(report.reason or "No reason provided"), inline = false },
            },
            footer = { text = ("Source: %s"):format(resourceName) },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
    }
    local payload = { username = Config.WebhookName, avatar_url = (Config.WebhookAvatar ~= "" and Config.WebhookAvatar or nil), embeds = embed }
    local encoded = json.encode(payload)
    PerformHttpRequest(Config.ReportWebhook, function(statusCode, response, headers)
        if statusCode >= 200 and statusCode < 300 then
            logf("Sent report ID %s to Discord webhook (HTTP %s)", tostring(report.id), tostring(statusCode))
        else
            logf("Failed to send report ID %s to Discord webhook. HTTP %s response: %s", tostring(report.id), tostring(statusCode), tostring(response))
        end
    end, 'POST', encoded, { ['Content-Type'] = 'application/json' })
end

-- report endpoints (kept)
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
    saveReportsToFile()
    SendDiscordReport(report)
    TriggerClientEvent('adminmenu:client:newReport', -1, report)
    logf("[REPORT] %s (ID:%s) reported %s (ID:%s) for: %s", tostring(reporterName), tostring(src), tostring(targetName), tostring(targetId), tostring(reason))
end)

RegisterNetEvent('adminmenu:server:createReportForScreenshot')
AddEventHandler('adminmenu:server:createReportForScreenshot', function(targetId, reason, reporterName, targetName, filetype, expectedTotal)
    local src = source
    local ft = tostring(filetype or "jpg")
    local expected = tonumber(expectedTotal) or nil
    local time = os.date('%Y-%m-%d %H:%M:%S')
    local report = {
        id = reportIdCounter,
        reporterId = src,
        reporterName = reporterName or ("Player "..tostring(src)),
        targetId = targetId,
        targetName = targetName or tostring(targetId),
        reason = reason,
        time = time,
        resolved = false
    }
    local assignedId = reportIdCounter
    reports[assignedId] = report
    reportIdCounter = reportIdCounter + 1
    saveReportsToFile()
    TriggerClientEvent('adminmenu:client:newReport', -1, report)
    logf("Created report id=%s (waiting for screenshot) reporter=%s target=%s", tostring(assignedId), tostring(src), tostring(targetId))

    screenshotBuffers[assignedId] = { parts = {}, total = expected, received = 0, filetype = ft, creator = src, createdAt = os.time() }
    TriggerClientEvent('adminmenu:client:reportCreated', src, assignedId)
end)

RegisterNetEvent('adminmenu:server:uploadScreenshotChunk')
AddEventHandler('adminmenu:server:uploadScreenshotChunk', function(reportId, index, total, chunk)
    local src = source
    reportId = tonumber(reportId); index = tonumber(index); total = tonumber(total); chunk = tostring(chunk or "")
    if not reportId or not index or not total or chunk == "" then
        logf("uploadScreenshotChunk: invalid args from %s", tostring(src)); return
    end
    if #chunk > 20000 then logf("uploadScreenshotChunk: chunk too large from %s", tostring(src)); return end
    local buf = screenshotBuffers[reportId]
    if not buf then logf("uploadScreenshotChunk: no buffer for report %s from %s", tostring(reportId), tostring(src)); return end
    if total > 500 then logf("uploadScreenshotChunk: rejected too many parts %s for report %s", tostring(total), tostring(reportId)); cleanupScreenshotBuffer(reportId); return end
    if not buf.parts[index] then
        buf.parts[index] = chunk
        local cnt = 0
        for i=1,total do if buf.parts[i] then cnt = cnt + 1 end end
        buf.received = cnt; buf.total = total
    else
        logf("uploadScreenshotChunk: duplicate chunk %d for report %s ignored", index, tostring(reportId))
    end
    logf("Buffer for report %s -> received=%d total=%s (got chunk %d size=%d)", tostring(reportId), tostring(buf.received), tostring(buf.total or total), index, #chunk)

    if buf.received >= buf.total and buf.total and buf.total > 0 then
        local missing = {}
        for i=1,buf.total do if not buf.parts[i] then table.insert(missing, i) end end
        if #missing > 0 then logf("ERROR: missing parts for report %s -> %s", tostring(reportId), table.concat(missing, ",")); return end
        local assembled = table.concat(buf.parts)
        if not assembled or assembled == "" then logf("ERROR assembling parts for report %s", tostring(reportId)); cleanupScreenshotBuffer(reportId); return end
        local report = reports[reportId]
        if not report then logf("ERROR: no report record id=%s when attempting upload", tostring(reportId)); cleanupScreenshotBuffer(reportId); return end
        logf("All chunks received for report %s, size(base64)=%d - storing", tostring(reportId), #assembled)
        report.screenshot = assembled
        report.screenshotFiletype = buf.filetype or "png"
        saveReportsToFile()
        local mime = tostring(report.screenshotFiletype or "png"):gsub("%W","")
        local dataUrl = ("data:image/%s;base64,%s"):format(mime, assembled)
        TriggerClientEvent('adminmenu:client:reportScreenshot', -1, reportId, dataUrl)
        SendDiscordReport(report)
        cleanupScreenshotBuffer(reportId)
    end
end)

RegisterNetEvent('adminmenu:server:finalizeScreenshotUpload')
AddEventHandler('adminmenu:server:finalizeScreenshotUpload', function(reportId)
    reportId = tonumber(reportId); if not reportId then return end
    local buf = screenshotBuffers[reportId]; if not buf then logf("finalizeScreenshotUpload: no buffer for %s", tostring(reportId)); return end
    logf("finalizeScreenshotUpload called for %s (received=%s total=%s)", tostring(reportId), tostring(buf.received), tostring(buf.total))
end)

RegisterNetEvent('adminmenu:server:resolveReport')
AddEventHandler('adminmenu:server:resolveReport', function(reportId)
    if reports[reportId] then reports[reportId].resolved = true; saveReportsToFile(); TriggerClientEvent('adminmenu:client:updateReport', -1, reportId, true) end
end)

RegisterNetEvent('adminmenu:server:deleteReport')
AddEventHandler('adminmenu:server:deleteReport', function(reportId)
    if reports[reportId] then reports[reportId] = nil; saveReportsToFile(); TriggerClientEvent('adminmenu:client:removeReport', -1, reportId) end
end)

RegisterNetEvent('adminmenu:serverBring')
AddEventHandler('adminmenu:serverBring', function(data)
    local src = source
    local target = tonumber((data and data.target) or data)
    if not target then
        logf("Bring: invalid target from %s", tostring(src)); return
    end
    -- Ask the target client to teleport to the admin (brought)
    TriggerClientEvent('adminmenu:clientTeleportTo', target, { type = 'bring', admin = src, target = target })
    -- Notify the admin client to update UI/confirm
    TriggerClientEvent('adminmenu:clientActionAck', src, { action = 'bring', target = target })
    logf("Bring: admin %s bringing %s", tostring(src), tostring(target))
end)

RegisterNetEvent('adminmenu:serverTeleportTo')
AddEventHandler('adminmenu:serverTeleportTo', function(data)
    local src = source
    local target = tonumber((data and data.target) or data)
    if not target then
        logf("TeleportTo: invalid target from %s", tostring(src)); return
    end
    -- Ask the admin client to teleport to the target (go to)
    TriggerClientEvent('adminmenu:clientTeleportTo', src, { type = 'goto', admin = src, target = target })
    TriggerClientEvent('adminmenu:clientActionAck', src, { action = 'teleport', target = target })
    logf("Teleport: admin %s -> %s", tostring(src), tostring(target))
end)

RegisterNetEvent('adminmenu:serverToggleFreeze')
AddEventHandler('adminmenu:serverToggleFreeze', function(data)
    local src = source
    local target = tonumber(data.target)
    local shouldFreeze = (data.freeze == nil) and true or not not data.freeze
    if not target then logf("ToggleFreeze: invalid target from %s", tostring(src)); return end
    TriggerClientEvent('adminmenu:clientSetFreeze', target, { freeze = shouldFreeze, admin = src })
    logf("Freeze: admin %s set freeze=%s on %s", tostring(src), tostring(shouldFreeze), tostring(target))
    TriggerClientEvent('adminmenu:clientActionAck', src, { action = 'freeze', target = target, freeze = shouldFreeze })
end)

RegisterNetEvent('adminmenu:serverKick')
AddEventHandler('adminmenu:serverKick', function(data)
    local src = source
    local target = tonumber(data.target)
    local reason = tostring(data.reason or "Kicked by admin")
    if not target then logf("Kick: invalid target from %s", tostring(src)); return end
    DropPlayer(target, reason)
    logf("Kick: admin %s kicked %s for: %s", tostring(src), tostring(target), tostring(reason))
    TriggerClientEvent('adminmenu:clientActionAck', src, { action = 'kick', target = target })
end)

RegisterNetEvent('adminmenu:serverBan')
AddEventHandler('adminmenu:serverBan', function(data)
    local src = source
    local target = tonumber(data.target)
    local reason = tostring(data.reason or "Banned by admin")
    if not target then logf("Ban: invalid target from %s", tostring(src)); return end
    TriggerEvent('adminmenu:banPlayer', target, reason)
    DropPlayer(target, reason)
    logf("Ban: admin %s banned %s for: %s", tostring(src), tostring(target), tostring(reason))
    TriggerClientEvent('adminmenu:clientActionAck', src, { action = 'ban', target = target })
end)

-- Send reports and screenshots on request
RegisterNetEvent('adminmenu:serverGetReports')
AddEventHandler('adminmenu:serverGetReports', function()
    local src = source
    local out = {}
    for id, rep in pairs(reports) do
        table.insert(out, {
            id = rep.id, reporterId = rep.reporterId, reporterName = rep.reporterName,
            targetId = rep.targetId, targetName = rep.targetName, reason = rep.reason,
            time = rep.time, resolved = rep.resolved, screenshotFiletype = rep.screenshotFiletype
        })
    end
    table.sort(out, function(a,b) return (b.id or 0) < (a.id or 0) end)
    TriggerClientEvent('adminmenu:client:loadReports', src, out)

    for id, rep in pairs(reports) do
        if rep.screenshot and rep.screenshotFiletype then
            local mime = tostring(rep.screenshotFiletype or "png"):gsub("%W","")
            local dataUrl = ("data:image/%s;base64,%s"):format(mime, rep.screenshot)
            TriggerClientEvent('adminmenu:client:reportScreenshot', src, id, dataUrl)
        end
    end
end)

-- ===== Enhanced serverGetPlayers (robust) =====
-- We'll aggregate from server + ask clients when server list looks incomplete.
local pendingLocalPlayerRequests = {} -- requestId -> { src = <requester>, map = { [id]=true }, timer = <handle> }

RegisterNetEvent('adminmenu:serverGetPlayers')
AddEventHandler('adminmenu:serverGetPlayers', function(requestId)
    local src = source
    local out = {}

    local players = GetPlayers() or {}
    logf("serverGetPlayers: GetPlayers() returned %d entries (requestId=%s) for %s", #players, tostring(requestId), tostring(src))

    -- Build server-side list first
    for i, sid in ipairs(players) do
        local pid = tonumber(sid)
        local name = nil
        if pid then
            name = GetPlayerName(pid) or ("Player "..tostring(pid))
        else
            name = tostring(sid)
        end

        local discord = ""
        if pid then
            local d = getDiscordForServerId(pid)
            if d then discord = d end
        end

        local entry = { id = (pid or sid), name = name, discord = (discord or "") }
        table.insert(out, entry)
        logf("  server-list -> idx=%d id=%s name=%s discord=%s", i, tostring(entry.id), tostring(entry.name), tostring(entry.discord))
    end

    if #out <= 1 then
        logf("serverGetPlayers: server-side list small (<=1). requesting client-side enumerations (requestId=%s)", tostring(requestId))
        pendingLocalPlayerRequests[requestId] = { src = src, map = {}, timer = nil }

        for _, entry in ipairs(out) do
            pendingLocalPlayerRequests[requestId].map[tostring(entry.id)] = entry
        end

        TriggerClientEvent('adminmenu:clientRequestLocalPlayers', -1, requestId)

        pendingLocalPlayerRequests[requestId].timer = Citizen.SetTimeout(1200, function()
            local agg = pendingLocalPlayerRequests[requestId]
            if not agg then return end
            local final = {}
            for idStr, val in pairs(agg.map) do
                if type(val) == 'table' then
                    table.insert(final, { id = val.id, name = val.name, discord = val.discord or "" })
                else
                    local pid = tonumber(idStr)
                    local name = pid and GetPlayerName(pid) or ("Player "..tostring(idStr))
                    local discord = ""
                    if pid then local d = getDiscordForServerId(pid); if d then discord = d end end
                    table.insert(final, { id = pid or idStr, name = name, discord = discord })
                end
            end
            table.sort(final, function(a,b) return tostring(a.name) < tostring(b.name) end)

            -- verbose log the aggregated list
            for i, p in ipairs(final) do
                logf("  aggregated -> idx=%d id=%s name=%s discord=%s", i, tostring(p.id), tostring(p.name), tostring(p.discord))
            end

            TriggerClientEvent('adminmenu:clientLoadPlayers', agg.src, tostring(requestId), final)
            pendingLocalPlayerRequests[requestId] = nil
            logf("serverGetPlayers: delivered aggregated list (count=%d) to %s for requestId=%s", #final, tostring(agg.src), tostring(requestId))
        end)

        return
    end

    -- If server-side list looks fine, send with requestId as string
    TriggerClientEvent('adminmenu:clientLoadPlayers', src, tostring(requestId), out)
    logf("Provided players list to %s (count=%d)", tostring(src), #out)
end)

-- Server: receive client-local player list and aggregate when a pending request is present
RegisterNetEvent('adminmenu:serverReceiveLocalPlayers')
AddEventHandler('adminmenu:serverReceiveLocalPlayers', function(requestId, players)
    local src = source
    requestId = tostring(requestId or "")
    local pending = pendingLocalPlayerRequests[requestId]
    local out = players or {}
    logf("serverReceiveLocalPlayers: received %d players from client %s for requestId=%s", #out, tostring(src), requestId)
    if not pending then
        -- no pending aggregate — this can happen if server already sent response. Just forward to the requester (best-effort)
        -- If the original requester exists, forward; otherwise ignore.
        if requestId and requestId ~= "" then
            logf("serverReceiveLocalPlayers: no pending aggregation for %s — forwarding directly to sender %s", tostring(requestId), tostring(src))
            TriggerClientEvent('adminmenu:clientLoadPlayers', src, tostring(requestId), out)
        end
        return
    end

    -- Merge incoming players into pending.map (dedupe by id)
    for _, p in ipairs(out) do
        local idKey = tostring(p.id)
        if not pending.map[idKey] then
            pending.map[idKey] = { id = p.id, name = p.name, discord = p.discord or "" }
        end
    end
end)

RegisterNetEvent('adminmenu:serverRequestPlayerDiscord')
AddEventHandler('adminmenu:serverRequestPlayerDiscord', function(targetId)
    local src = source
    local t = tonumber(targetId)
    if not t then TriggerClientEvent('adminmenu:clientPlayerDiscord', src, targetId, nil); return end
    local discord = getDiscordForServerId(t)
    TriggerClientEvent('adminmenu:clientPlayerDiscord', src, t, discord)
end)

RegisterNetEvent('adminmenu:verifyAdmin')
AddEventHandler('adminmenu:verifyAdmin', function()
    local src = source
    logf("Event fired, source = %s", tostring(src))
    local got = false
    if exports and exports['Az-Framework'] and exports['Az-Framework'].isAdmin then
        logf("Calling Az-Framework:isAdmin for %s", tostring(src))
        exports['Az-Framework']:isAdmin(src, function(isAdmin)
            got = true
            if exports['Az-Framework'] and exports['Az-Framework'].logAdminCommand then
                exports['Az-Framework']:logAdminCommand('adminmenu', src, {}, isAdmin)
                logf("logAdminCommand done for %s", tostring(src))
            end
            if isAdmin then TriggerClientEvent('adminmenu:allowOpen', src) else TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'You are not authorized.' } }) end
        end)
    else
        logf("Az-Framework:isAdmin not present; fallback (console only allowed).")
        if src == 0 then TriggerClientEvent('adminmenu:allowOpen', src) end
        got = true
    end
    Citizen.SetTimeout(5000, function() if not got then logf("WARNING: isAdmin callback timed out for %s", tostring(src)) end end)
end)

AddEventHandler('onResourceStart', function(res)
    if res == resourceName then
        loadReportsFromFile()
    end
end)

-- (rest of file — departments, money handlers, etc. remain unchanged)
-- ===== NUI-driven department endpoints =====
-- Returns current departments to the requesting client
RegisterNetEvent('adminmenu:serverGetDepartments')
AddEventHandler('adminmenu:serverGetDepartments', function()
    local src = source
    TriggerClientEvent('adminmenu:clientReceiveDepartments', src, { departments = departments or {} })
end)

-- Create a department (data: { department, paycheck, discordid })
RegisterNetEvent('adminmenu:serverCreateDepartment')
AddEventHandler('adminmenu:serverCreateDepartment', function(data)
    local src = source
    if not data or not data.department then return end
    table.insert(departments, { department = tostring(data.department), paycheck = tonumber(data.paycheck) or 0, discordid = tostring(data.discordid or "") })
    logf("Department created by %s -> %s", tostring(src), tostring(data.department))
    TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
end)

-- addmoney department (data: { department, paycheck, discordid })
RegisterNetEvent('adminmenu:serveraddmoneyDepartment')
AddEventHandler('adminmenu:serveraddmoneyDepartment', function(data)
    local src = source
    if not data or not data.department then return end
    for i, d in ipairs(departments) do
        if d.department == data.department then
            d.paycheck = tonumber(data.paycheck) or d.paycheck
            d.discordid = tostring(data.discordid or d.discordid)
            logf("Department modified by %s -> %s", tostring(src), tostring(data.department))
            break
        end
    end
    TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
end)

-- Remove department (data: { department, discordid })
RegisterNetEvent('adminmenu:serverRemoveDepartment')
AddEventHandler('adminmenu:serverRemoveDepartment', function(data)
    local src = source
    if not data or not data.department then return end
    for i = #departments, 1, -1 do
        local d = departments[i]
        if d.department == data.department and (not data.discordid or d.discordid == tostring(data.discordid)) then
            table.remove(departments, i)
            logf("Department removed by %s -> %s", tostring(src), tostring(data.department))
        end
    end
    TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
end)

-- robust serverMoneyOp (safe)
local recentMoneyOps = {} -- [targetId] = timestamp
local MONEY_OP_COOLDOWN_MS = 1500
local MONEY_AMOUNT_LIMIT = 10000000

RegisterNetEvent('adminmenu:serverMoneyOp')
AddEventHandler('adminmenu:serverMoneyOp', function(data)
    local src = source
    if type(data) ~= 'table' then
        TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'Invalid money-op payload.' } })
        return
    end

    local op = tostring(data.op or '')
    local target = tonumber(data.target)
    local amount = tonumber(data.amount) or 0
    local extra = data.extra

    if not target then
        TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'Invalid target ID.' } })
        return
    end

    if amount == 0 and op ~= 'transfer' and op ~= 'addmoney' then
        TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'Please enter a valid (non-zero) amount.' } })
        return
    end

    if math.abs(amount) > MONEY_AMOUNT_LIMIT then
        TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', ('Amount too large (max %s).'):format(MONEY_AMOUNT_LIMIT) } })
        return
    end

    local now = GetGameTimer and GetGameTimer() or (os.time() * 1000)
    if recentMoneyOps[target] and (now - recentMoneyOps[target] < MONEY_OP_COOLDOWN_MS) then
        TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'Money ops are being throttled for that player. Try again shortly.' } })
        return
    end
    recentMoneyOps[target] = now

    logf("MoneyOp requested by %s -> op=%s target=%s amount=%s extra=%s", tostring(src), op, tostring(target), tostring(amount), tostring(extra))

    local handled = false
    local ok, res

    -- 1) Az-Framework server exports (if present)
    if exports and exports['Az-Framework'] then
        if op == 'add' then ok, res = pcall(function() return exports['Az-Framework']:addMoney(target, amount) end); handled = handled or (ok and res ~= false) end
        if (not handled) and op == 'deduct' then ok, res = pcall(function() return exports['Az-Framework']:deductMoney(target, amount) end); handled = handled or (ok and res ~= false) end
        if (not handled) and op == 'addmoney' then ok, res = pcall(function() return exports['Az-Framework']:addMoney(target, amount) end); handled = handled or (ok and res ~= false) end
        if (not handled) and op == 'deposit' then ok, res = pcall(function() return exports['Az-Framework']:depositMoney(target, amount) end); handled = handled or (ok and res ~= false) end
        if (not handled) and op == 'withdraw' then ok, res = pcall(function() return exports['Az-Framework']:withdrawMoney(target, amount) end); handled = handled or (ok and res ~= false) end
        if (not handled) and op == 'transfer' then
            ok, res = pcall(function() return exports['Az-Framework']:transferMoney(target, tonumber(extra), amount) end)
            handled = handled or (ok and res ~= false)
            if not handled then ok, res = pcall(function() return exports['Az-Framework']:transferMoney(tonumber(extra), target, amount) end); handled = handled or (ok and res ~= false) end
        end
    end

    -- 2) QBCore (server-side)
    if (not handled) and exports and exports['qb-core'] then
        pcall(function()
            local QBCore = exports['qb-core']:GetCoreObject()
            if QBCore and QBCore.Functions then
                local player = QBCore.Functions.GetPlayer(target)
                if player then
                    if op == 'add' then player.Functions.AddMoney('cash', amount) handled = true end
                    if op == 'deduct' then player.Functions.RemoveMoney('cash', amount) handled = true end
                    if op == 'deposit' then player.Functions.RemoveMoney('cash', amount); player.Functions.AddMoney('bank', amount); handled = true end
                    if op == 'withdraw' then player.Functions.RemoveMoney('bank', amount); player.Functions.AddMoney('cash', amount); handled = true end
                    -- addmoney/transfer implementations may require more context
                end
            end
        end)
    end

    -- 3) ESX (server-side)
    if (not handled) and ESX then
        pcall(function()
            local xPlayer = ESX.GetPlayerFromId(target)
            if xPlayer then
                if op == 'add' then xPlayer.addMoney(amount); handled = true end
                if op == 'deduct' then xPlayer.removeMoney(amount); handled = true end
                if op == 'deposit' then xPlayer.removeMoney(amount); xPlayer.addAccountMoney('bank', amount); handled = true end
                if op == 'withdraw' then xPlayer.removeAccountMoney('bank', amount); xPlayer.addMoney(amount); handled = true end
            end
        end)
    end

    if handled then
        TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', ('Money op %s executed on %s for %s'):format(op, tostring(target), tostring(amount)) } })
        logf("MoneyOp handled server-side: op=%s target=%s amount=%s", tostring(op), tostring(target), tostring(amount))
        return
    end

    logf("MoneyOp NOT handled server-side: op=%s target=%s amount=%s", tostring(op), tostring(target), tostring(amount))
    TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'Money operation could not be completed server-side. Configure your economy framework or use the debug command to detect available APIs.' } })
end)

