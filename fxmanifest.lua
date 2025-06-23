fx_version 'cerulean'
game 'gta5'
author 'Azure(TheStoicBear)'
description 'Azure Framework Admin Panel'
version '1.0.0'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    's_admin.lua'
}

client_scripts {
    'c_admin.lua'
}

ui_page 'html/ui.html'

files {
    'html/ui.html',
}
