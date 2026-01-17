Az-Admin
=======

Features
- /report <serverId> <reason...> : submits a report (optionally with screenshot-basic).
- /adminmenu : opens the Admin Menu (ACE permission gated).
- Reports UI (list + detail + resolve/delete)
- Players UI (discord lookup + teleport/bring/freeze/kick/ban wiring points)
- Money Operations (server-side framework-aware handlers)
- Departments Management (DB-backed)

SQL
- See sql/schema.sql for econ_departments table + indexes.

Notes
- This UI is self-contained (no external CDNs) to avoid NUI CSP issues.
- For screenshots, install screenshot-basic OR keep NUI capture stub.


ACE Permissions
- Add this to server.cfg (example):
  add_ace group.admin azadmin.use allow
  add_principal identifier.discord:YOURDISCORDID group.admin

