fx_version 'cerulean'
game 'gta5'
author 'Azure(TheStoicBear)'
description 'Azure Framework Admin Panel'
version '2.5.1'
lua54 'yes'
shared_scripts {
    "@Az-Framework/init.lua",  -- gives you global `Az`
    '@ox_lib/init.lua',
}

client_scripts {
    'client.lua'
}
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config_s.lua',
    'server.lua'
}

ui_page 'html/ui.html'

files {
    'html/ui.html',
    'html/styles.css',
    'reports.json'
}

