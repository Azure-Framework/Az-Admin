fx_version 'cerulean'
game 'gta5'
author 'Azure(TheStoicBear)'
description 'Azure Framework Admin Panel'
version '1.0.0'
lua54 'yes'

shared_script  '@ox_lib/init.lua'

client_scripts {
    'client.lua'
}
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

ui_page 'html/ui.html'

files {
    'html/ui.html',
    'html/styles.css',
}
