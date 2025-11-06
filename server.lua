-- server.lua — Admin Menu (DB-backed departments + /report with screenshot attachment, overflow-safe)
-- Resource: Az-Admin
-- Date: 2025-11-02

-- ============================================================================
-- JSON helper (FiveM usually exposes json.encode/json.decode; fall back if not)
-- ============================================================================
local json = json or (require and require('json'))

-- ============================================================================
-- Config (env via convars)
-- ============================================================================
Config = Config or {}

-- Discord webhook to receive reports (embeds + attached screenshot)
Config.ReportWebhook = Config.ReportWebhook or GetConvar('ADMIN_REPORT_WEBHOOK', '')
Config.WebhookName   = Config.WebhookName   or GetConvar('ADMIN_REPORT_BOTNAME', 'Server Reports')
Config.WebhookAvatar = Config.WebhookAvatar or GetConvar('ADMIN_REPORT_AVATAR', '')
Config.EmbedColor    = Config.EmbedColor    or 3066993 -- azure-ish

-- Screenshot chunking preferences that the SERVER will advertise to the client
-- NOTE: Final chunk size & latent usage MUST be implemented by the client.
local CHUNK_MAX_SIZE       = 8000     -- bytes per chunk payload (base64 chars). Keep <= 8k to avoid overflows.
local LATENT_BANDWIDTH_BPS = 12000    -- suggested latent bandwidth for client when sending
local CHUNK_ASSEMBLY_LIMIT = 600      -- hard cap on number of parts the server will accept

local resourceName = GetCurrentResourceName() or "resource"
local reportsFile  = "reports.json"

-- ============================================================================
-- Logging helpers
-- ============================================================================
local function logf(fmt, ...)
    print(("[admin:%s] " .. (fmt or "%s")):format(resourceName, ...))
end

-- ============================================================================
-- Discord & screenshot helpers
-- ============================================================================
local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64decode(data)
    data = data:gsub('[^'..b..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(b:find(x)-1)
        for i=6,1,-1 do r = r .. (f%2^i - f%2^(i-1) > 0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c = c + (x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

-- Strict CRLFs
local CRLF = "\r\n"

-- Build multipart/form-data body for Discord webhook with a single file (classic webhook style)
-- Uses name="file" for the uploaded part; no "attachments" array needed for webhooks.
-- === replace your multipart builder with this ===
local CRLF = "\r\n"

local function build_multipart_with_file(payload_tbl, filename, mime, file_bytes)
    local boundary = ('------------------------%d%d'):format(os.time(), math.random(1e8, 2e8))
    local parts = {}

    -- payload_json first (Discord is tolerant, but this order helps avoid 400s)
    parts[#parts+1] = "--" .. boundary .. CRLF
    parts[#parts+1] = 'Content-Disposition: form-data; name="payload_json"' .. CRLF
    parts[#parts+1] = "Content-Type: application/json" .. CRLF .. CRLF
    parts[#parts+1] = json.encode(payload_tbl) .. CRLF

    -- file as files[0]
    parts[#parts+1] = "--" .. boundary .. CRLF
    parts[#parts+1] = ('Content-Disposition: form-data; name="files[0]"; filename="%s"'):format(filename) .. CRLF
    parts[#parts+1] = ('Content-Type: %s'):format(mime or "application/octet-stream") .. CRLF .. CRLF
    parts[#parts+1] = file_bytes .. CRLF

    parts[#parts+1] = "--" .. boundary .. "--" .. CRLF

    local body = table.concat(parts)
    local headers = {
        ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
    }
    return body, headers
end

-- === replace your SendDiscordReport with this ===
local function SendDiscordReport(report)
    if not Config.ReportWebhook or Config.ReportWebhook == "" then
        logf("Report webhook not configured; skipping Discord post.")
        return
    end

    local embed = {
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

    local base_payload = {
        username   = (Config.WebhookName ~= "" and Config.WebhookName or nil),
        avatar_url = (Config.WebhookAvatar ~= "" and Config.WebhookAvatar or nil),
        embeds     = { embed },
    }

    -- no screenshot? send JSON embed only
    if not report.screenshot or report.screenshot == "" then
        PerformHttpRequest(Config.ReportWebhook, function(sc, resp)
            logf("Webhook (no image) status=%s body=%s", tostring(sc), tostring(resp))
        end, "POST", json.encode(base_payload), { ["Content-Type"] = "application/json" })
        return
    end

    -- with screenshot
    local ft = tostring(report.screenshotFiletype or "png"):lower()
    if ft == "jpg" then ft = "jpeg" end
    if ft ~= "png" and ft ~= "jpeg" and ft ~= "webp" then ft = "png" end
    local filename = ("report-%s.%s"):format(tostring(report.id or ('r'..os.time())), ft)
    local mime = "image/" .. ft

    -- decode base64 into raw bytes
    local raw = (function(b64)
        local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        b64 = (b64 or ""):gsub('[^'..b..'=]', '')
        return (b64:gsub('.', function(x)
            if x=='=' then return '' end
            local r,f='',(b:find(x)-1)
            for i=6,1,-1 do r = r .. (f%2^i - f%2^(i-1) > 0 and '1' or '0') end
            return r
        end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
            if #x~=8 then return '' end
            local c=0; for i=1,8 do c = c + (x:sub(i,i)=='1' and 2^(8-i) or 0) end
            return string.char(c)
        end))
    end)(report.screenshot)

    if not raw or #raw == 0 then
        logf("Base64 decode empty; sending embed without image.")
        PerformHttpRequest(Config.ReportWebhook, function(sc, resp)
            logf("Webhook (no image) status=%s body=%s", tostring(sc), tostring(resp))
        end, "POST", json.encode(base_payload), { ["Content-Type"] = "application/json" })
        return
    end

    if #raw > (24 * 1024 * 1024) then
        logf("Attachment too large for webhook (%d bytes). Sending embed without image.", #raw)
        PerformHttpRequest(Config.ReportWebhook, function(sc, resp)
            logf("Webhook (no image) status=%s body=%s", tostring(sc), tostring(resp))
        end, "POST", json.encode(base_payload), { ["Content-Type"] = "application/json" })
        return
    end

    -- IMPORTANT: declare the attachment (id=0) and reference it in the embed
    embed.image = { url = "attachment://" .. filename }
    local payload_with_attachment = {
        username   = base_payload.username,
        avatar_url = base_payload.avatar_url,
        embeds     = { embed },
        attachments = {
            { id = 0, filename = filename }
        }
    }

    local body, headers = build_multipart_with_file(payload_with_attachment, filename, mime, raw)
    PerformHttpRequest(Config.ReportWebhook, function(statusCode, response)
        if statusCode and statusCode >= 200 and statusCode < 300 then
            logf("Webhook with image OK (HTTP %s)", tostring(statusCode))
        else
            logf("Discord webhook failed (HTTP %s). Falling back to embed without image. Resp: %s", tostring(statusCode), tostring(response))
            -- Send JSON-only fallback without embed.image
            local e = {}; for k,v in pairs(embed) do e[k]=v end; e.image = nil
            PerformHttpRequest(Config.ReportWebhook, function(sc2, resp2)
                logf("Fallback webhook status=%s body=%s", tostring(sc2), tostring(resp2))
            end, "POST", json.encode({ username=base_payload.username, avatar_url=base_payload.avatar_url, embeds={e} }), { ["Content-Type"]="application/json" })
        end
    end, "POST", body, headers)
end


-- Post a report to Discord. If report.screenshot (base64) exists, attach it.
local function SendDiscordReport(report)
    if not Config.ReportWebhook or Config.ReportWebhook == "" then
        logf("Report webhook not configured; skipping Discord post.")
        return
    end

    local embed = {
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

    -- Base payload (we’ll add embed.image if we have a file)
    local payload = {
        username   = (Config.WebhookName ~= "" and Config.WebhookName or nil),
        avatar_url = (Config.WebhookAvatar ~= "" and Config.WebhookAvatar or nil),
        embeds     = { embed }
    }

    -- If we have a screenshot, send multipart with 'file' and embed.image pointing to attachment://
    if report.screenshot and report.screenshot ~= "" then
        local ft = tostring(report.screenshotFiletype or "png"):lower()
        if ft == "jpg" then ft = "jpeg" end
        if ft ~= "png" and ft ~= "jpeg" and ft ~= "webp" then ft = "png" end
        local filename = ("report-%s.%s"):format(tostring(report.id or ('r'..os.time())), ft)
        local mime = "image/" .. ft

        local raw = b64decode(report.screenshot or "")
        if raw and #raw > 0 then
            if #raw > (24 * 1024 * 1024) then
                logf("Attachment too large for webhook (%d bytes). Sending embed without image.", #raw)
                PerformHttpRequest(Config.ReportWebhook, function(sc, resp)
                    logf("Webhook (no image) status=%s", tostring(sc))
                end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
                return
            end

            -- For classic webhooks: just reference attachment://<filename> in the embed.
            embed.image = { url = "attachment://" .. filename }

            local body, headers = build_multipart_with_file(payload, filename, mime, raw)
            PerformHttpRequest(Config.ReportWebhook, function(statusCode, response)
                if statusCode ~= nil and statusCode >= 200 and statusCode < 300 then
                    logf("Sent report ID %s to Discord with ATTACHMENT (HTTP %s)", tostring(report.id), tostring(statusCode))
                else
                    logf("Discord webhook failed (HTTP %s). Falling back to embed without image. Resp: %s", tostring(statusCode), tostring(response))
                    PerformHttpRequest(Config.ReportWebhook, function(sc2, r2)
                        logf("Fallback webhook status=%s body=%s", tostring(sc2), tostring(r2))
                    end, 'POST', json.encode({
                        username   = payload.username,
                        avatar_url = payload.avatar_url,
                        embeds     = { (function()
                            local e = {}
                            for k,v in pairs(embed) do e[k]=v end
                            e.image = nil -- remove image when sending JSON-only fallback
                            return e
                        end)() }
                    }), { ['Content-Type'] = 'application/json' })
                end
            end, 'POST', body, headers)
            return
        else
            logf("Screenshot present but base64 decode yielded empty; sending embed without image.")
        end
    end

    -- No screenshot: simple JSON
    PerformHttpRequest(Config.ReportWebhook, function(statusCode, response)
        if statusCode ~= nil and statusCode >= 200 and statusCode < 300 then
            logf("Sent report ID %s to Discord webhook (HTTP %s)", tostring(report.id), tostring(statusCode))
        else
            logf("Failed to send report ID %s to Discord webhook. HTTP %s response: %s", tostring(report.id), tostring(statusCode), tostring(response))
        end
    end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
end

-- ============================================================================
-- Reports storage (file-backed so restarts persist summary list)
-- ============================================================================
local reports = {}
local reportIdCounter = 1
local screenshotBuffers = {}

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
    for _, p in ipairs(paths) do
        local content, _ = tryReadFile(p)
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
    logf("%s not found; starting with empty reports", reportsFile)
end

local function saveReportsToFile()
    local arr = {}
    for id, r in pairs(reports) do table.insert(arr, r) end
    table.sort(arr, function(a,b) return (a.id or 0) < (b.id or 0) end)
    local ok, encoded = pcall(function() return json.encode(arr) end)
    if not ok then
        logf("Failed to encode reports to JSON: %s", tostring(encoded))
        return
    end
    for _, p in ipairs(candidatePaths()) do
        local written = tryWriteFile(p, encoded)
        if written then
            logf("Saved %d reports to %s", #arr, p)
            return
        end
    end
    logf("ERROR: Could not write %s to any candidate path.", reportsFile)
end

-- screenshot buffer cleanup watchdog
local function cleanupScreenshotBuffer(reportId) screenshotBuffers[reportId] = nil end
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30 * 1000)
        local now = os.time()
        for id, buf in pairs(screenshotBuffers) do
            if buf.createdAt and now - buf.createdAt > 180 then
                logf("Cleaning stale screenshot buffer id=%s (age=%ds)", tostring(id), now - buf.createdAt)
                cleanupScreenshotBuffer(id)
            end
        end
    end
end)

-- ============================================================================
-- Player identity helper
-- ============================================================================
local function getDiscordForServerId(sid)
    if not sid then return nil end
    local ids = GetPlayerIdentifiers(sid) or {}
    for _, ident in ipairs(ids) do
        if tostring(ident):sub(1,8) == "discord:" then
            return tostring(ident):sub(9)
        end
    end
    return nil
end

-- ============================================================================
-- DB helpers (oxmysql / mysql-async compatible)
-- ============================================================================
local function db_query(sql, params, cb)
    params = params or {}
    if exports and exports.oxmysql and exports.oxmysql.query then
        return exports.oxmysql:query(sql, params, cb)
    end
    if MySQL and MySQL.query then
        return MySQL.query(sql, params, cb)
    end
    if MySQL and MySQL.Async and MySQL.Async.fetchAll then
        MySQL.Async.fetchAll(sql, params, function(result) if cb then cb(result) end end)
        return
    end
    logf("^1No MySQL adapter found. Unable to query: %s^0", sql)
    if cb then cb({}) end
end

local function db_exec(sql, params, cb)
    params = params or {}
    if exports and exports.oxmysql and exports.oxmysql.update then
        return exports.oxmysql:update(sql, params, cb)
    end
    if MySQL and MySQL.update then
        return MySQL.update(sql, params, cb)
    end
    if MySQL and MySQL.Async and MySQL.Async.execute then
        MySQL.Async.execute(sql, params, function(affected) if cb then cb(affected) end end)
        return
    end
    logf("^1No MySQL adapter found. Unable to exec: %s^0", sql)
    if cb then cb(0) end
end

-- Fetch departments from DB (schema: econ_departments)
local function fetchDepartments(cb)
    db_query([[
        SELECT discordid, charid, department, paycheck
        FROM econ_departments
        ORDER BY department ASC, discordid ASC
    ]], {}, function(rows)
        rows = rows or {}
        cb(rows)
    end)
end

-- ============================================================================
-- Net events — Reports (with screenshot chunking)
-- ============================================================================
local function adviseClientChunking(src)
    TriggerClientEvent('adminmenu:client:uploadAdvice', src, {
        maxChunk     = CHUNK_MAX_SIZE,
        useLatent    = true,
        bandwidthBps = LATENT_BANDWIDTH_BPS
    })
end

RegisterNetEvent('adminmenu:server:submitReport')
AddEventHandler('adminmenu:server:submitReport', function(targetId, reason, reporterName, targetName)
    local src = source
    local time = os.date('%Y-%m-%d %H:%M:%S')
    local report = {
        id = reportIdCounter,
        reporterId = src,
        reporterName = reporterName or ("Player "..tostring(src)),
        targetId = targetId,
        targetName = targetName or tostring(targetId),
        reason = reason or "No reason provided",
        time = time,
        resolved = false
    }
    reports[reportIdCounter] = report
    reportIdCounter = reportIdCounter + 1
    saveReportsToFile()
    SendDiscordReport(report)
    TriggerClientEvent('adminmenu:client:newReport', -1, report)
    logf("[REPORT] %s (ID:%s) reported %s (ID:%s) for: %s", tostring(report.reporterName), tostring(src), tostring(report.targetName), tostring(targetId), tostring(reason))
end)

RegisterNetEvent('adminmenu:server:createReportForScreenshot')
AddEventHandler('adminmenu:server:createReportForScreenshot', function(targetId, reason, reporterName, targetName, filetype, expectedTotal)
    local src = source
    local time = os.date('%Y-%m-%d %H:%M:%S')
    local report = {
        id = reportIdCounter,
        reporterId = src,
        reporterName = reporterName or ("Player "..tostring(src)),
        targetId = targetId,
        targetName = targetName or tostring(targetId),
        reason = reason or "No reason provided",
        time = time,
        resolved = false
    }
    local assignedId = reportIdCounter
    reports[assignedId] = report
    reportIdCounter = reportIdCounter + 1
    saveReportsToFile()
    TriggerClientEvent('adminmenu:client:newReport', -1, report)
    logf("Created report id=%s (awaiting screenshot) reporter=%s target=%s", tostring(assignedId), tostring(src), tostring(targetId))

    screenshotBuffers[assignedId] = {
        parts = {},
        total = tonumber(expectedTotal) or nil,
        received = 0,
        filetype = tostring(filetype or "png"),
        creator = src,
        createdAt = os.time()
    }

    adviseClientChunking(src)
    TriggerClientEvent('adminmenu:client:reportCreated', src, assignedId)
end)

RegisterNetEvent('adminmenu:server:uploadScreenshotChunk')
AddEventHandler('adminmenu:server:uploadScreenshotChunk', function(reportId, index, total, chunk)
    local src = source
    reportId = tonumber(reportId); index = tonumber(index); total = tonumber(total); chunk = tostring(chunk or "")
    if not reportId or not index or not total or chunk == "" then
        logf("uploadScreenshotChunk: invalid args from %s", tostring(src)); return
    end

    if total > CHUNK_ASSEMBLY_LIMIT then
        logf("uploadScreenshotChunk: total parts %d exceeds assembly limit %d — rejecting", total, CHUNK_ASSEMBLY_LIMIT)
        TriggerClientEvent('adminmenu:client:uploadError', src, reportId, "too_many_parts")
        return
    end

    if #chunk > CHUNK_MAX_SIZE then
        logf("uploadScreenshotChunk: chunk too large (%d). Enforcing <= %d.", #chunk, CHUNK_MAX_SIZE)
        adviseClientChunking(src)
        TriggerClientEvent('adminmenu:client:uploadError', src, reportId, "chunk_too_large")
        return
    end

    local buf = screenshotBuffers[reportId]
    if not buf then logf("uploadScreenshotChunk: no buffer for report %s from %s", tostring(reportId), tostring(src)); return end

    if not buf.total then buf.total = total end
    if total ~= buf.total then
        logf("uploadScreenshotChunk: total mismatch for %s (was %s now %s)", tostring(reportId), tostring(buf.total), tostring(total))
        buf.total = math.max(buf.total, total)
        if buf.total > CHUNK_ASSEMBLY_LIMIT then
            TriggerClientEvent('adminmenu:client:uploadError', src, reportId, "too_many_parts")
            return
        end
    end

    if not buf.parts[index] then
        buf.parts[index] = chunk
        buf.received = buf.received + 1
    end

    if buf.received >= buf.total then
        -- assemble
        local missing = {}
        for i=1,buf.total do if not buf.parts[i] then table.insert(missing, i) end end
        if #missing > 0 then
            logf("uploadScreenshotChunk: missing parts for report %s -> %s", tostring(reportId), table.concat(missing, ","))
            TriggerClientEvent('adminmenu:client:uploadError', src, reportId, "missing_parts")
            return
        end
        local assembled = table.concat(buf.parts)
        if not assembled or assembled == "" then
            logf("uploadScreenshotChunk: assembled empty for report %s", tostring(reportId))
            cleanupScreenshotBuffer(reportId); return
        end
        local report = reports[reportId]
        if not report then
            logf("uploadScreenshotChunk: report %s no longer exists", tostring(reportId))
            cleanupScreenshotBuffer(reportId); return
        end

        report.screenshot = assembled
        report.screenshotFiletype = buf.filetype or "png"
        saveReportsToFile()

        -- push to all clients (for UI preview)
        local mime = tostring(report.screenshotFiletype or "png"):gsub("%W","")
        local dataUrl = ("data:image/%s;base64,%s"):format(mime, assembled)
        TriggerClientEvent('adminmenu:client:reportScreenshot', -1, reportId, dataUrl)

        -- Send to Discord (with attachment)
        SendDiscordReport(report)

        cleanupScreenshotBuffer(reportId)
        logf("Screenshot stored and dispatched for report %s", tostring(reportId))
    end
end)

RegisterNetEvent('adminmenu:server:finalizeScreenshotUpload')
AddEventHandler('adminmenu:server:finalizeScreenshotUpload', function(reportId)
    reportId = tonumber(reportId); if not reportId then return end
    local buf = screenshotBuffers[reportId]
    if not buf then return end
    logf("finalizeScreenshotUpload called for %s (received=%s total=%s)", tostring(reportId), tostring(buf.received), tostring(buf.total))
end)

-- Client requests full report list (+ cached screenshots)
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

RegisterNetEvent('adminmenu:server:resolveReport')
AddEventHandler('adminmenu:server:resolveReport', function(reportId)
    if reports[reportId] then reports[reportId].resolved = true; saveReportsToFile(); TriggerClientEvent('adminmenu:client:updateReport', -1, reportId, true) end
end)

RegisterNetEvent('adminmenu:server:deleteReport')
AddEventHandler('adminmenu:server:deleteReport', function(reportId)
    if reports[reportId] then reports[reportId] = nil; saveReportsToFile(); TriggerClientEvent('adminmenu:client:removeReport', -1, reportId) end
end)

-- ============================================================================
-- Players list
-- ============================================================================
local function serverGetPlayersList()
    local out = {}
    local players = GetPlayers() or {}
    for _, sid in ipairs(players) do
        local pid = tonumber(sid)
        local name = pid and (GetPlayerName(pid) or ("Player "..tostring(pid))) or tostring(sid)
        local discord = ""
        if pid then
            local d = getDiscordForServerId(pid)
            if d then discord = d end
        end
        out[#out+1] = { id = (pid or sid), name = name, discord = (discord or "") }
    end
    table.sort(out, function(a,b) return tostring(a.name) < tostring(b.name) end)
    return out
end

RegisterNetEvent('adminmenu:serverGetPlayers')
AddEventHandler('adminmenu:serverGetPlayers', function(requestId)
    local src = source
    local players = serverGetPlayersList()
    local found = false
    for _, p in ipairs(players) do if tostring(p.id) == tostring(src) then found = true break end end
    if not found then
        players[#players+1] = { id = src, name = GetPlayerName(src) or ("Player "..tostring(src)), discord = getDiscordForServerId(src) or "" }
    end
    TriggerClientEvent('adminmenu:clientLoadPlayers', src, requestId, players)
end)

RegisterNetEvent('adminmenu:serverRequestPlayerDiscord')
AddEventHandler('adminmenu:serverRequestPlayerDiscord', function(targetId)
    local src = source
    local t = tonumber(targetId)
    if not t then TriggerClientEvent('adminmenu:clientPlayerDiscord', src, targetId, nil); return end
    local discord = getDiscordForServerId(t)
    TriggerClientEvent('adminmenu:clientPlayerDiscord', src, t, discord)
end)

-- ============================================================================
-- Departments (DB-backed)
-- ============================================================================
RegisterNetEvent('adminmenu:serverGetDepartments')
AddEventHandler('adminmenu:serverGetDepartments', function()
    local src = source
    fetchDepartments(function(rows)
        TriggerClientEvent('adminmenu:clientReceiveDepartments', src, { departments = rows })
    end)
end)

RegisterNetEvent('adminmenu:serverCreateDepartment')
AddEventHandler('adminmenu:serverCreateDepartment', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local discordid  = tostring(data.discordid or '')
    local department = tostring(data.department or '')
    local paycheck   = tonumber(data.paycheck) or 0
    local charid     = tostring(data.charid or discordid)

    if discordid == '' or department == '' then return end

    db_exec([[
        INSERT INTO econ_departments (discordid, charid, department, paycheck)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE charid = VALUES(charid), paycheck = VALUES(paycheck)
    ]], { discordid, charid, department, paycheck }, function(_affected)
        fetchDepartments(function(rows)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = rows })
        end)
        logf("Department upsert by %s -> (%s, %s) paycheck=%s", tostring(src), discordid, department, tostring(paycheck))
    end)
end)

RegisterNetEvent('adminmenu:serverModifyDepartment')
AddEventHandler('adminmenu:serverModifyDepartment', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local discordid  = tostring(data.discordid or '')
    local department = tostring(data.department or '')
    local paycheck   = tonumber(data.paycheck) or 0
    local charid     = tostring(data.charid or discordid)

    if discordid == '' or department == '' then return end

    db_exec([[
        UPDATE econ_departments
        SET charid = ?, paycheck = ?
        WHERE discordid = ? AND department = ?
    ]], { charid, paycheck, discordid, department }, function(_affected)
        fetchDepartments(function(rows)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = rows })
        end)
        logf("Department modified by %s -> (%s, %s) paycheck=%s", tostring(src), discordid, department, tostring(paycheck))
    end)
end)

RegisterNetEvent('adminmenu:serverRemoveDepartment')
AddEventHandler('adminmenu:serverRemoveDepartment', function(data)
    local src = source
    if type(data) ~= 'table' then return end
    local discordid  = tostring(data.discordid or '')
    local department = tostring(data.department or '')

    if discordid == '' or department == '' then return end

    db_exec([[
        DELETE FROM econ_departments WHERE discordid = ? AND department = ?
    ]], { discordid, department }, function(_affected)
        fetchDepartments(function(rows)
            TriggerClientEvent('adminmenu:clientReceiveDepartments', -1, { departments = rows })
        end)
        logf("Department removed by %s -> (%s, %s)", tostring(src), discordid, department)
    end)
end)

-- ============================================================================
-- Verify admin (Az-Framework if present; console fallback)
-- ============================================================================
RegisterNetEvent('adminmenu:verifyAdmin')
AddEventHandler('adminmenu:verifyAdmin', function()
    local src = source
    local got = false
    if exports and exports['Az-Framework'] and exports['Az-Framework'].isAdmin then
        exports['Az-Framework']:isAdmin(src, function(isAdmin)
            got = true
            if exports['Az-Framework'] and exports['Az-Framework'].logAdminCommand then
                exports['Az-Framework']:logAdminCommand('adminmenu', src, {}, isAdmin)
            end
            if isAdmin then
                TriggerClientEvent('adminmenu:allowOpen', src)
            else
                TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'You are not authorized.' } })
            end
        end)
    else
        if src == 0 then TriggerClientEvent('adminmenu:allowOpen', src) end
        got = true
    end
    Citizen.SetTimeout(5000, function() if not got then logf("WARNING: isAdmin callback timed out for %s", tostring(src)) end end)
end)

-- ============================================================================
-- Money Ops (skeleton; integrates with frameworks if present)
-- ============================================================================
local recentMoneyOps = {}
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
        TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'Money ops are throttled for that player. Try again shortly.' } })
        return
    end
    recentMoneyOps[target] = now

    local handled = false
    local ok, res

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

    -- QBCore fallback
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
                end
            end
        end)
    end

    -- ESX fallback
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
    TriggerClientEvent('chat:addMessage', src, { args = { '[AdminMenu]', 'Money operation could not be completed server-side. Configure your economy framework.' } })
end)

-- ============================================================================
-- Lifecycle
-- ============================================================================
AddEventHandler('onResourceStart', function(res)
    if res == resourceName then
        loadReportsFromFile()
    end
end)
