# BasicServerCFT
This repository will be used to create a basic server and networking settings for testing AWS builds for R.App projects.  Entities will be iterated on over time to improve security and full-featured functionality.

## Process for Running
1.	Run Networksetup.template CFT first in the AWS console (will eventually move to API)
2.  Run BasicServerConfig.template to create a basic server (need to add load balancer next) 

## What is created?

1.  Network settings for basic application
2.  Server with autoscaling group and launch configuration


## Notes

### Userdata information
```
sudo useradd [username1]
sudo passwd [username2]
modified /etc/sshd_config and allowed authentication 3 lines above password search
```

### Connection Medium
Use "anywhere" inbound rule to start.
currently allowed in allaccess sg, need to create cft to do that
::/0 needs to be added to default security group at startup (adding into CFT)



