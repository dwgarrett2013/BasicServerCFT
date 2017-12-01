# BasicServerCFT
This repository will be used to create a basic server that will be used as the basis for future R.App projects.

## VPC Information
vpc-1eb45a76

## Subnet Information
subnet-a6aadceb

## Security Group Information
sg-f1bae299 

## Userdata information

```
sudo useradd [username1]
sudo passwd [username2]
modified /etc/sshd_config and allowed authentication 3 lines above password search
```

## Connection Medium
Use "anywhere" inbound rule to start.
currently allowed in allaccess sg, need to create cft to do that
::/0 needs to be added to default security group at startup (adding into CFT)



