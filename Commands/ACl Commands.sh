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

# To remove specific permissions for a user or group:

setfacl -x u:username /path/to/file_or_directory

setfacl -x g:groupname /path/to/file_or_directory

# To remove a specific user recursively:

setfacl -R -x u:username /path/to/directory

# To completely wipe ALL ACL permissions (returning the file to standard chmod permissions):

setfacl -b /path/to/file_or_directory

*(The `-b` flag stands for "remove all" or "baking away" the extra permissions).*

# To wipe ALL custom ACLs recursively:

setfacl -R -b /path/to/directory

# Remove a specific user from an entire folder tree
# If you just want to kick one user out of a directory and all its subfolders/files, use -R followed by -x:

setfacl -R -x u:username /path/to/directory

# Completely wipe ALL custom ACLs from an entire folder tree
# If you want to completely reset the directory and all its contents back to standard chmod permissions (clearing out all custom users and groups), use -R followed by -b:

setfacl -R -b /path/to/directory

# To completely clean the directory so it stops applying those rules to new files, add the -k flag:

setfacl -R -b -k /path/to/directory
