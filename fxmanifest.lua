fx_version 'cerulean'
game 'gta5'
author 'Azure(TheStoicBear)'
description 'Azure Framework Admin Panel'
version '1.0.0'
lua54 'yes'
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    's_admin.lua'
}
shared_script  '@ox_lib/init.lua'
client_scripts {
    'c_admin.lua'
}

ui_page 'html/ui.html'

files {
    'html/ui.html',
}
