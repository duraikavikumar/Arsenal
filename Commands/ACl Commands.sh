ACl Commands

# A) Set Directories: Read + Enter (No Write/Delete access)
find /project -type d -exec setfacl -m u:c1009:rX {} +

# B) Set Files: Read + Write
find /project -type f -exec setfacl -m u:c1009:rw- {} +

# Sets the ceiling for current items only.
setfacl -m m::rwx

# Sets the ceiling for all future items.
setfacl -d -m m::rwx

# Sets the user AND updates the default mask automatically.
setfacl -d -m u:user:rwX