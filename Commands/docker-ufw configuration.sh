# Docker configuration for UFW rule

# Ensure Network Stability (The Foundation)

# Create an static network with a static IP range (subnet and gateway)

# Verify Static Network Creation: Ensure you have already created the network with a permanent subnet:


docker network create --driver bridge --subnet 172.18.0.0/16 --gateway 172.18.0.1 network_name


# Configure Docker Compose (Recommended) to your docker-compose.yml to define a fixed, available subnet (e.g., 172.18.0.0/16) and assign static IPs to services you need to access externally.

 Assign static IPs to critical services 
 For service: my_service
networks:
  my_app_network:
    ipv4_address: 172.18.0.10


networks:
  network_name:
    external: true


# Step 1: Enable IP Forwarding (Kernel Prerequisite)

# Enable Forwarding in Configuration: Edit the file /etc/sysctl.conf and ensure the following line is uncommented and set to 1:

net.ipv4.ip_forward=1


# Apply the Change: Load the new settings immediately without rebooting:

sudo sysctl -p


# Step 2: Disable Docker's Default Firewall Management

# Edit Docker Daemon Configuration: Ensure your /etc/docker/daemon.json file contains the following (create the file if it doesn't exist):

{
  "iptables": false
}


# Restart Docker: Apply the change by restarting the Docker service.

sudo systemctl restart docker

# Outbound Internet Access (Masquerade)

# once the docker's own iptables was set to false the containers will lose the internet access to restore that we have to add the following rules.

# Edit /etc/ufw/before.rules to add the NAT Masnqerade configuration which will restore the internet connection

#
# Nat table
#
*nat
:PREROUTING ACCEPT [0:0]

# ... (DNAT rules) ...

:POSTROUTING ACCEPT [0:0]

# --- START DOCKER MASQUERADE ---
# Allows any packet originating from the stable 172.18.0.0/16 subnet 
# to masquerade (NAT) when it leaves the external interface (ens160).
-A POSTROUTING -s 172.18.0.0/16 -o ens160 -j MASQUERADE
# --- END DOCKER MASQUERADE ---

COMMIT

# Insert this in the *nat table's POSTROUTING chain
-A POSTROUTING -s 172.18.0.0/16 -o <EXTERNAL_NIC> -j MASQUERADE	

# The above configuration should be added before/above the *filter line to take effect


# If the port needs to the external network outside the server we have to add the DNAT configuration on the before.rule file, once the iptables was set to false the docker will no longer manage the DNAT rules for the ports that are exposing in to the internet

# This doesn't apply incase the container is using reverse proxy to manage traffic.

# DNAT Rule (in before.rules): Redirect incoming traffic to container IP
-A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 172.18.0.10:8080

# UFW Allow Command (on host)
sudo ufw allow 8080/tcp


# The IP specifies the containers IP and port is the one that is being exposed from the container and the rule has to be added for each and every port that are being exposed individually.


# Allow Host $\leftrightarrow$ Container Forwarding (FORWARD Chain)

# Allows routed traffic to flow between the bridge and the external NIC
# This covers the internal host proxy -> container communication.
sudo ufw route allow out on ens160 from 172.18.0.0/16   

br-d04c1dfd85db- user defined bridge network interface name 

ens160- host's network interface name

can be optained from using the command < ip a >


# Allow Container to Host Services (INPUT Chain)

# This is necessary if containers need to reach host services (like a database running on port 3306).

# Example: Allow containers to reach a Host-side database on port 3306.
# By specifying 'from 172.18.0.0/16', only your containers can access it.
sudo ufw allow from 172.18.0.0/16 to any port 3306 proto tcp


# Finally reload

sudo ufw reload




docker-ufw configurations

IPforwarding should be enabled

ufw default polices are deny 

defaul deny incoming, outgoing and routed

and to disable docker's override

{

iptables=false

}

on the /etc/docker/daemon.json


NAT rules for the container internet access


Routed rules for bridge network to form the route between host's interface and the docker's bridge network (ip default routed policy is denied, otherwise NAT is enough)


sudo ufw route allow in on <host's interface> out on <bridge network>
sudo ufw route allow in on br-17da799937d6 out on <host's interface>


And for port access dedicated port rules need for the container from the host


ufw allow in from <container_subnet> to any port <port>

ufw allow out to <container_subnet> port <port>