fx_version 'cerulean'
game 'gta5'

name 'Az-Admin'
author 'Azure'
description 'Admin Menu: Reports + Players + Money Ops + DB Departments (NUI)'
version '1.0.0'
lua54 'yes'

ui_page 'html/index.html'

files {
  'html/index.html',
  'html/style.css',
  'html/app.js',
  'data/reports.json',
  'sql/schema.sql'
}

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua'
}

client_scripts {
  'client.lua'
}

server_scripts {
  'server.lua'
}

dependencies {
  'oxmysql',
  'ox_lib'
}
