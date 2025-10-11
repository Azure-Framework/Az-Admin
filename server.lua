local json = json or (require and require('json'))

Config = Config or {}
Config.ReportWebhook = Config.ReportWebhook or ""
Config.EmbedColor    = Config.EmbedColor or 3066993
Config.WebhookName   = Config.WebhookName or "Server Reports"
Config.WebhookAvatar = Config.WebhookAvatar or ""

local resourceName = GetCurrentResourceName() or "resource"
local reportsFile = "reports.json"


local reports = {}
local reportIdCounter = 1
local departments = {} 
local screenshotBuffers = {}

local function logf(fmt, ...) print(("[admin] " .. (fmt or "%s")):format(...)) end


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
        if base and base ~= "" then
            
            base = normalizePath(base)
            return base
        end
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

local function tryReadFile(path)
    if not path then return nil, "invalid-path" end
    local np = normalizePath(path)
    local f, err = io.open(np, "r")
    if not f then return nil, tostring(err) end
    local content = f:read("*a")
    f:close()
    return content
end

local function ensureDirForFile(filePath)
    if not filePath or filePath == "" then return end
    local normalized = normalizePath(filePath)
    local parent = normalized:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" then
        
        local ok, e = pcall(function()
            local testPath = parent .. (SEP == '/' and "/.touch" or "\\.touch")
            local fh = io.open(testPath, "w")
            if fh then fh:write("x"); fh:close(); os.remove(testPath) end
        end)
        if not ok then
            
            if SEP == '/' then
                pcall(function() os.execute(('mkdir -p "%s"'):format(parent)) end)
            else
                pcall(function() os.execute(('mkdir "%s" >nul 2>nul'):format(parent)) end)
            end
        end
    end
end

local function tryWriteFile(path, data)
    if not path then return false, "invalid-path" end
    local np = normalizePath(path)
    ensureDirForFile(np)
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
    local tried = {}
    local loaded = false
    local paths = candidatePaths()
    logf("Looking for reports.json in %d candidate path(s).", #paths)
    for _, p in ipairs(paths) do
        local content, err = tryReadFile(p)
        table.insert(tried, { path = p, ok = content ~= nil, err = err })
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
                loaded = true
                break
            else
                logf("Found %s but JSON decode failed, skipping.", p)
            end
        end
    end
    if not loaded then
        for _, t in ipairs(tried) do
            logf("loadReportsFromFile attempt: path=%s ok=%s err=%s", t.path, tostring(t.ok), tostring(t.err))
        end
        logf("%s not found in resource paths; starting with empty reports", reportsFile)
    end
end


local function saveReportsToFile()
    local arr = {}
    for id, r in pairs(reports) do table.insert(arr, r) end
    local ok, encoded = pcall(function() return json.encode(arr) end)
    if not ok then
        logf("Failed to encode reports to JSON: %s", tostring(encoded))
        return
    end

    local tried = {}
    local success = false
    for _, p in ipairs(candidatePaths()) do
        local written, err = tryWriteFile(p, encoded)
        table.insert(tried, { path = p, ok = written, err = err })
        if written then
            logf("Saved %d reports to %s", #arr, p)
            success = true
            break
        end
    end
    if not success then
        for _, t in ipairs(tried) do
            logf("saveReportsToFile attempt: path=%s ok=%s err=%s", t.path, tostring(t.ok), tostring(t.err))
        end
        logf("ERROR: Could not write reports.json to resource paths.")
    end
end



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


RegisterNetEvent('adminmenu:serverBring'); AddEventHandler('adminmenu:serverBring', function(data) local src = source; local target = tonumber(data.target); if not target then return end; TriggerClientEvent('adminmenu:clientTeleportTo', target, src); logf("Bring: admin %s bringing %s", tostring(src), tostring(target)) end)
RegisterNetEvent('adminmenu:serverTeleportTo'); AddEventHandler('adminmenu:serverTeleportTo', function(data) local src = source; local target = tonumber(data.target); if not target then return end; TriggerClientEvent('adminmenu:clientTeleportTo', src, target); logf("Teleport: admin %s -> %s", tostring(src), tostring(target)) end)
RegisterNetEvent('adminmenu:serverToggleFreeze'); AddEventHandler('adminmenu:serverToggleFreeze', function(data) local src = source; local target = tonumber(data.target); local shouldFreeze = data.freeze; if shouldFreeze==nil then shouldFreeze=true end; if not target then return end; TriggerClientEvent('adminmenu:clientSetFreeze', target, shouldFreeze); logf("Freeze: admin %s set freeze=%s on %s", tostring(src), tostring(shouldFreeze), tostring(target)) end)
RegisterNetEvent('adminmenu:serverKick'); AddEventHandler('adminmenu:serverKick', function(data) local src = source; local target = tonumber(data.target); local reason = tostring(data.reason or "Kicked by admin"); if not target then return end; DropPlayer(target, reason); logf("Kick: admin %s kicked %s for: %s", tostring(src), tostring(target), tostring(reason)) end)
RegisterNetEvent('adminmenu:serverBan'); AddEventHandler('adminmenu:serverBan', function(data) local src = source; local target = tonumber(data.target); local reason = tostring(data.reason or "Banned by admin"); if not target then return end; TriggerEvent('adminmenu:banPlayer', target, reason); DropPlayer(target, reason); logf("Ban: admin %s banned %s for: %s", tostring(src), tostring(target), tostring(reason)) end)


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




local function db_exec(query, params, cb)
    
    if exports and exports.oxmysql and exports.oxmysql.execute then
        return exports.oxmysql:execute(query, params or {}, cb)
    end
    
    if exports and exports.ghmattimysql and exports.ghmattimysql.execute then
        return exports.ghmattimysql:execute(query, params or {}, cb)
    end
    
    if MySQL and MySQL.Async and MySQL.Async.fetchAll then
        
        if string.lower((query or ""):sub(1,6)) == "select" then
            return MySQL.Async.fetchAll(query, params or {}, cb)
        else
            return MySQL.Async.execute(query, params or {}, cb)
        end
    end
    return nil
end

local function loadDepartmentsFromDBOrFallback()
    local connected = false
    local selectQ = "SELECT discordid, department, paycheck FROM econ_departments"
    local handled = false
    
    local ok, res = pcall(function()
        if exports and exports.oxmysql and exports.oxmysql.execute then
            exports.oxmysql:execute(selectQ, {}, function(rows)
                departments = {}
                for _, r in ipairs(rows or {}) do table.insert(departments, { department = r.department, paycheck = tonumber(r.paycheck) or 0, discordid = r.discordid or "" }) end
                TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
                logf("Loaded %d departments from oxmysql", #departments)
            end)
            handled = true
        elseif exports and exports.ghmattimysql and exports.ghmattimysql.execute then
            exports.ghmattimysql:execute(selectQ, {}, function(rows)
                departments = {}
                for _, r in ipairs(rows or {}) do table.insert(departments, { department = r.department, paycheck = tonumber(r.paycheck) or 0, discordid = r.discordid or "" }) end
                TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
                logf("Loaded %d departments from ghmattimysql", #departments)
            end)
            handled = true
        elseif MySQL and MySQL.Async and MySQL.Async.fetchAll then
            MySQL.Async.fetchAll(selectQ, {}, function(rows)
                departments = {}
                for _, r in ipairs(rows or {}) do table.insert(departments, { department = r.department, paycheck = tonumber(r.paycheck) or 0, discordid = r.discordid or "" }) end
                TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
                logf("Loaded %d departments from mysql-async", #departments)
            end)
            handled = true
        end
    end)
    if not handled then
        
        logf("No DB connector found; using in-memory departments (count=%d)", #departments)
        TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
    end
end


RegisterNetEvent('adminmenu:serverGetDepartments')
AddEventHandler('adminmenu:serverGetDepartments', function()
    local src = source
    TriggerClientEvent('adminmenu:clientReceiveDepartments', src, { departments = departments })
end)


RegisterNetEvent('adminmenu:serverCreateDepartment')
AddEventHandler('adminmenu:serverCreateDepartment', function(data)
    local src = source
    local dept = tostring(data.department or "")
    local paycheck = tonumber(data.paycheck) or 0
    local discordid = tostring(data.discordid or "")
    if dept == "" then return end

    -- Normal insert (will fail with duplicate-key if (discordid,department) PK exists)
    local insertQ = "INSERT INTO econ_departments (discordid, department, paycheck) VALUES (@discordid, @department, @paycheck)"
    local params = { ['@discordid'] = discordid, ['@department'] = dept, ['@paycheck'] = paycheck }

    local executed = false
    if exports and exports.oxmysql and exports.oxmysql.execute then
        executed = true
        exports.oxmysql:execute(insertQ, params, function(af)
            table.insert(departments, { department = dept, paycheck = paycheck, discordid = discordid })
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Created department '%s' (oxmysql)", dept)
        end)
    elseif exports and exports.ghmattimysql and exports.ghmattimysql.execute then
        executed = true
        exports.ghmattimysql:execute(insertQ, params, function(af)
            table.insert(departments, { department = dept, paycheck = paycheck, discordid = discordid })
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Created department '%s' (ghmattimysql)", dept)
        end)
    elseif MySQL and MySQL.Async and MySQL.Async.execute then
        executed = true
        MySQL.Async.execute(insertQ, params, function(af)
            table.insert(departments, { department = dept, paycheck = paycheck, discordid = discordid })
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Created department '%s' (mysql-async)", dept)
        end)
    end

    if not executed then
        table.insert(departments, { department = dept, paycheck = paycheck, discordid = discordid })
        TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
        logf("Created department '%s' (in-memory)", dept)
    end
end)


RegisterNetEvent('adminmenu:serverModifyDepartment')
AddEventHandler('adminmenu:serverModifyDepartment', function(data)
    local src = source
    local dept = tostring(data.department or "")
    local paycheck = tonumber(data.paycheck) or 0
    local discordid = tostring(data.discordid or "")
    if dept == "" then return end

    local updated = false
    for i,v in ipairs(departments) do
        if v.department == dept then
            v.paycheck = paycheck; v.discordid = discordid; updated = true; break
        end
    end

    local executed = false
    local updateQ = "UPDATE econ_departments SET paycheck=@paycheck, discordid=@discordid WHERE department=@department"
    local params = { ['@paycheck'] = paycheck, ['@discordid'] = discordid, ['@department'] = dept }

    if exports and exports.oxmysql and exports.oxmysql.execute then
        executed = true
        exports.oxmysql:execute(updateQ, params, function(af)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Modified department '%s' (oxmysql)", dept)
        end)
    elseif exports and exports.ghmattimysql and exports.ghmattimysql.execute then
        executed = true
        exports.ghmattimysql:execute(updateQ, params, function(af)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Modified department '%s' (ghmattimysql)", dept)
        end)
    elseif MySQL and MySQL.Async and MySQL.Async.execute then
        executed = true
        MySQL.Async.execute(updateQ, params, function(af)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Modified department '%s' (mysql-async)", dept)
        end)
    end

    if not executed then
        TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
        logf("Modified department '%s' (in-memory)", dept)
    end
end)


RegisterNetEvent('adminmenu:serverRemoveDepartment')
AddEventHandler('adminmenu:serverRemoveDepartment', function(data)
    local src = source
    local dept = tostring(data.department or "")
    if dept == "" then return end

    for i=#departments,1,-1 do
        if departments[i].department == dept then table.remove(departments, i) end
    end

    local executed = false
    local deleteQ = "DELETE FROM econ_departments WHERE department=@department"
    local params = { ['@department'] = dept }

    if exports and exports.oxmysql and exports.oxmysql.execute then
        executed = true
        exports.oxmysql:execute(deleteQ, params, function(af)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Removed department '%s' (oxmysql)", dept)
        end)
    elseif exports and exports.ghmattimysql and exports.ghmattimysql.execute then
        executed = true
        exports.ghmattimysql:execute(deleteQ, params, function(af)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Removed department '%s' (ghmattimysql)", dept)
        end)
    elseif MySQL and MySQL.Async and MySQL.Async.execute then
        executed = true
        MySQL.Async.execute(deleteQ, params, function(af)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
            logf("Removed department '%s' (mysql-async)", dept)
        end)
    end

    if not executed then
        TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = departments })
        logf("Removed department '%s' (in-memory)", dept)
    end
end)


local function getDiscordForServerId(sid)
    if not sid then return nil end
    local ids = GetPlayerIdentifiers(sid)
    if not ids then return nil end
    for _, ident in ipairs(ids) do
        if tostring(ident):sub(1,8) == "discord:" then return tostring(ident):sub(9) end
    end
    return nil
end

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
        loadDepartmentsFromDBOrFallback()
    end
end)



