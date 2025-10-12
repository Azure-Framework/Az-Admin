# Az-Admin
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/d59f9fc8-efab-4812-897d-97da8726de53" />
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/17a937c7-1789-45fe-be98-4f55b1da464c" />



## 🛡️ Enhanced Admin Panel for Azure Framework

**Az-Admin** is a feature-rich, modern administrative solution for the Azure Framework. It provides server staff with a powerful and intuitive **web-based UI** to efficiently manage player reports, enforce server rules, and perform essential financial and departmental controls directly within the game.

---

## ✨ Core Features

### 🧑‍⚖️ Player Reports Management
A centralized system for handling player-submitted reports:
* **Report Tracking:** View lists of **Pending** and **Resolved** reports.
* **Detailed View:** Each report displays the submitter, message, timestamp, and supports **media attachments** (e.g., images).
* **Direct Actions:** Staff can instantly **Resolve**, **Delete**, or **Teleport** to the location of the reported player for quick intervention.

### 🔨 Admin Tools
Comprehensive controls for managing active players and in-game economy:
* **Player Actions:** Execute critical moderation commands on selected players, including **Kick**, **Ban**, **Teleport**, **Bring** (teleport to staff), and **Freeze**.
* **Financial Management:** Directly adjust a player's funds by selecting an amount and confirming the transaction.

### 🚨 Departmental Management
Oversight and control of server-side organizations or factions:
* **Department Listing:** View all configured departments (e.g., BCSO, police).
* **Financial Oversight:** See the current funds associated with the department's account.
* **Direct Control:** Options to edit (update funds) or delete departmental accounts.

---

## 💻 Technical Details

| File | Purpose |
| :--- | :--- |
| `html/ui.html`, `html/css` | Renders the modern, dark-themed, and responsive **Enhanced Admin Panel UI**. |
| `client.lua` | Handles keybinds, UI logic, and sending requests to the server. |
| `server.lua` | Manages permissions, executes moderation actions (Kick, Ban, Freeze), processes financial changes, and handles report submission/resolution securely. |
| `fxmanifest.lua` | Standard FiveM resource configuration file. |

---

## 🚀 Installation & Usage

1.  **Download:** Clone the repository or download the latest release.
2.  **Placement:** Place the `Az-Admin` folder into your server's `resources` directory.
3.  **Start:** Add `ensure Az-Admin` to your server's `server.cfg` file.
4.  **Access:** The panel is accessed via  **command** (/adminmenu).
5.  **Permissions:** Ensure staff members have the required permissions set up in your framework to use the panel's functions.
