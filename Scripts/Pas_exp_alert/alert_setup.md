# Email alert setup for user account password expiry #

Requried packgaes to send the email using the external smtp server:

```
sudo apt update
sudo apt install -y msmtp msmtp-mta mailutils
```


SMTP configuration on the server after installation
```
sudo nano /etc/msmtprc
```
```
###############################################################################
#                                                                             #
#              Alerts configuration - User Password expiry                    #
#                                                                             #
###############################################################################

# Set default values for all profiles
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
#logfile        /var/log/msmtp.log
syslog			on

# Custom SMTP Provider Profile
account        custom_provider
host           smtp.zeptomail.in
port           587
from           notification@aliceblueindia.com
user           emailapikey
password       PHtE6r1fQeG/2m978kJU5PKxF8LwZosv/uozKwFPsd5DCv5VTU1Wqox5xme0qRouUvdLQKLInt87te/PtOyALG24YT0dWWqyqK3sx/VYSPOZsbq6x00at14YdEbdUoTmdtdj0SzTud3SNA==

# Assign profile as the default routing mechanism
account default : custom_provider
```

Required permission and ownership of the configuration
```
sudo chmod 600 /etc/msmtprc
sudo chown root:root /etc/msmtprc
```
