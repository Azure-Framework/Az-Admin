Config = Config or {}

-- Debug prints
Config.Debug = Config.Debug ~= false

-- Discord report webhook (override via convars ADMIN_REPORT_WEBHOOK, etc.)
Config.ReportWebhook = Config.ReportWebhook or GetConvar('ADMIN_REPORT_WEBHOOK', '')
Config.WebhookName   = Config.WebhookName   or GetConvar('ADMIN_REPORT_BOTNAME', 'Server Reports')
Config.WebhookAvatar = Config.WebhookAvatar or GetConvar('ADMIN_REPORT_AVATAR', '')
Config.EmbedColor    = tonumber(GetConvar('ADMIN_REPORT_EMBED_COLOR', '3066993')) or 3066993

-- Permission: if Az-Framework export isAdmin exists, it will be used.
-- Otherwise, you can grant access via ACE:
--   add_ace group.admin adminmenu.use allow
--   add_principal identifier.discord:XXXX group.admin
Config.AcePermission = 'adminmenu.use'

-- Reports persistence file (relative to resource)
Config.ReportsFile = 'reports.json'

-- Screenshot chunking safeguards
Config.ChunkMaxSize = tonumber(GetConvar('ADMIN_REPORT_CHUNK_MAX', '8000')) or 8000
Config.ChunkMaxParts = tonumber(GetConvar('ADMIN_REPORT_CHUNK_PARTS', '600')) or 600
Config.LatentBandwidthBps = tonumber(GetConvar('ADMIN_REPORT_LATENT_BW', '12000')) or 12000

-- Econ departments table
Config.DepartmentsTable = GetConvar('ADMIN_DEPARTMENTS_TABLE', 'econ_departments')
