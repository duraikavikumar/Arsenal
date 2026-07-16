### ---- Crontab issues ---- ###

Crontab Permission denied issue

```
/etc/cron.allow: Permission denied
You (username) are not allowed to use this program (crontab)
# OR
crontabs: username fopen: Permission denied
```

This is caused by the either user not in the cron.allow file or user present in the cron.deny file
either way user won't be able to access it.

Either we can add the user with the issue to the cron.allow file or remove the user from the cron.deny
file to resolve the permission denied 

cron.allow file
user1
user2
user3


If the crontab don't have read permission to the cron.allow even the user's exist on the file,
crontab won't be accessible for any users

either the ownership and permissions should be 

640 -rw-r---- root:root /etc/cron.allow with acl to the crontab group(setfacl -m g:crontab:r /etc/cron.allow)

or

640 -rw-r---- root:crontab /etc/cron.allow



If the cron is working but non root users are not able to open their crontabs with the following error

"[ Path '/tmp/crontab.XXXXXX' is not accessible ]"

inside the editor and on the terminal once closed

"Temporary crontab no longer owned by you. Error while editing crontab"

then need to check the following files ownership and permissions

# 1. Check the crontab binary permissions
ls -l /usr/bin/crontab

# 2. Check the user database spool permissions
ls -ld /var/spool/cron/crontabs
ls -l /var/spool/cron/crontabs/

# 3. Check for active ACLs on cron.allow
ls -la /etc/cron.allow

# 4. Check the kernel protection level
sysctl fs.protected_regular


The correct permissions and ownership are below

For /usr/bin/crontab - permission should be 2755 and ownership root:crontab

For /var/spool/cron/crontabs permission 1730 and ownership is root:crontab

For /var/spool/cron/crontabs/user01 permission 600 and ownership is user01:crontab

