# Linux User Delegation & Sudoers Personal Cheatsheet

reference guide for user switching, granting basic sudo privileges, defining command aliases, and configuring `/etc/sudoers` directly vs. using `/etc/sudoers.d/` in Ubuntu Server (22.04 / 24.04 LTS).

---

## 1. Modifying `/etc/sudoers` Directly vs. Using `/etc/sudoers.d/`

### Direct Editing Rules
1. **NEVER edit `/etc/sudoers` with a standard text editor** (`nano`, `vim`, etc.). Always use:

   ```bash
   sudo visudo
   ```

   `visudo` locks the file against concurrent edits and checks syntax before saving to prevent breaking `sudo` system-wide.


2. **Where to place custom configurations inside `/etc/sudoers`:**
   * Custom rules **MUST** be placed **below** the default system defaults and aliases (typically near the bottom of the file).
   * Put rules **above** the final `#includedir /etc/sudoers.d` directive if you want drop-in files to override them, or below it if you want main file entries to take precedence.

---

## 2. Main Sudoers File Layout (`/etc/sudoers`) & Insert Locations

When you run `sudo visudo`, your `/etc/sudoers` file follows this default structure. Insert your custom configurations at the designated locations shown below:

```bash
# /etc/sudoers
#
# This file MUST be edited with the 'visudo' command as root.

# Defaults specification
Defaults        env_reset
Defaults        mail_badpass
Defaults        secure_path="/usr/local/sbin:/usr/local/bin:/usr/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

# Host alias specification

# User alias specification
# ===> PLACE USER ALIASES HERE <===
User_Alias DELEGATED_TARGETS = user_b, user_c, user_d
User_Alias DEV_TEAM = user_a1, user_a2

# Cmnd alias specification
# ===> PLACE COMMAND ALIASES HERE <===
Cmnd_Alias APP_SERVICES = /usr/bin/systemctl restart nginx,                            /usr/bin/systemctl reload nginx,                            /usr/bin/systemctl status nginx

Cmnd_Alias DIAGNOSTICS = /usr/bin/htop, /usr/bin/journalctl

# User privilege specification
root    ALL=(ALL:ALL) ALL

# Members of the admin group may gain root privileges
%admin ALL=(ALL) ALL

# Allow members of group sudo to execute any command
%sudo   ALL=(ALL:ALL) ALL

# =========================================================================
# ===> PLACE YOUR CUSTOM RULES HERE (BEFORE #includedir) <===
# =========================================================================

# 1. Granting Full Sudo Access to a Regular User (Password Prompt)
john ALL=(ALL:ALL) ALL

# 2. Granting Full Sudo Access to a Regular User (Passwordless)
ops_admin ALL=(ALL:ALL) NOPASSWD: ALL

# 3. User-to-User Switching (No Root Access, Passwordless)
user_a ALL=(DELEGATED_TARGETS) NOPASSWD: ALL

# 4. Restricting User to Specific Command Aliases Only
DEV_TEAM ALL=(root) NOPASSWD: APP_SERVICES
dev_user ALL=(root) DIAGNOSTICS

# =========================================================================

# See sudoers(5) for more information on "@include" directives:
#includedir /etc/sudoers.d
```

---

## 3. Configuration Breakdown & Syntax Reference

### A. User-to-User Switching (No Root Access)
Allows `user_a` to switch to specific accounts (`user_b`, `user_c`) without root permissions or `su`:

* **In `/etc/sudoers` or `/etc/sudoers.d/`:**
  ```text
  user_a ALL=(user_b, user_c) NOPASSWD: ALL
  ```
* **Execution by `user_a`:**
  ```bash
  sudo -u user_b -i
  ```

---

### B. Granting Sudo Privileges to a Regular User

#### Option 1: Standard Group Membership (Easiest)
```bash
sudo usermod -aG sudo username
```

#### Option 2: Direct File Entry via `sudo visudo`
```text
# Requires user's own password
username ALL=(ALL:ALL) ALL

# Passwordless execution
username ALL=(ALL:ALL) NOPASSWD: ALL
```

---

### C. Command Aliases (`Cmnd_Alias`) for Restricted Access

Restrict users to exact binary commands (always use full paths from `which <command>`):

```text
# Define Alias
Cmnd_Alias NET_TOOLS = /usr/sbin/ufw, /usr/sbin/iptables

# Assign Alias
net_admin ALL=(root) NOPASSWD: NET_TOOLS
```

---

## 4. Quick Reference & Useful Commands

| Task | Command / Syntax |
| :--- | :--- |
| **Safely edit main sudoers file** | `sudo visudo` |
| **Safely edit drop-in file** | `sudo visudo -f /etc/sudoers.d/<filename>` |
| **Verify sudoers syntax without saving** | `sudo visudo -c` |
| **Check allowed sudo commands for current user** | `sudo -l` |
| **Verify binary path for `Cmnd_Alias`** | `which <command>` |
| **Audit sudo / user-switch events** | `sudo journalctl -u sudo -f` |

---

## 5. Common Errors & Troubleshooting

### `sudo: unknown user <name>`
* **Cause:** Misspelled username or account missing from `/etc/passwd`.
* **Fix:** Verify user existence: `id <username>`.

### `sudo: error initializing audit plugin sudoers_audit`
* **Cause:** Default log warning on Ubuntu 24.04 when a user lookup fails early.
* **Fix:** Non-fatal warning; ensure target username is spelled correctly.

### `visudo: syntax error`
* **Cause:** Formatting mistake or incorrect syntax in sudoers file.
* **Fix:** `visudo` detects this before saving and prompts you to re-edit (`e`). Never force quit or save broken syntax.
