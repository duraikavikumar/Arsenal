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

# To remove default permissions for a user or group:

setfacl -x d:u:username /path/to/file_or_directory

setfacl -x d:g:groupname /path/to/file_or_directory

# To remove the acl for a specific user recursively both current and default:

setfacl -R -x u:username /path/to/directory

setfacl -R -x d:u:username /path/to/directory

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


The most common uses are:

1. Add or modify multiple ACL entries (-m)

Instead of:

setfacl -m u:alice:rwx /dir
setfacl -m g:dev:r-x /dir
setfacl -m d:u:alice:rwx /dir
setfacl -m d:g:dev:r-x /dir

You can do:

setfacl -m u:alice:rwx,g:dev:r-x,d:u:alice:rwx,d:g:dev:r-x /dir
2. Remove multiple ACL entries (-x)
setfacl -x u:alice,g:dev,d:u:alice,d:g:dev /dir
3. Combine with recursion (-R)
setfacl -R -m u:alice:r-x,g:dev:r-x /data

or

setfacl -R -x u:alice,g:dev,d:u:alice,d:g:dev /data
4. Mix users, groups, masks, and others

You can specify several ACL entry types in one command:

setfacl -m u:alice:rwx,g:dev:r-x,m:r-x,o:--- /dir

This sets:

u:alice:rwx
g:dev:r-x
mask::r-x
other::---

all in one operation.

5. Default ACLs

You can also set multiple default ACLs together:

setfacl -m d:u:alice:rwx,d:g:dev:r-x,d:o:--- /dir
General rule

Any option that accepts an ACL specification (-m or -x) accepts a comma-separated list of ACL entries.

Examples:

# Multiple users
setfacl -m u:alice:rwx,u:bob:r-x /dir

# Multiple groups
setfacl -m g:dev:rwx,g:qa:r-x /dir

# Mix everything
setfacl -m u:alice:rwx,g:dev:r-x,d:u:alice:rwx,d:g:dev:r-x,m:rwx /dir

This is the preferred way to manage ACLs because it updates all the specified entries in a single invocation instead of running setfacl repeatedly.