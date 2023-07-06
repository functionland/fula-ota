
# Fula OTA based on docker solution

## Linux Prequestics

### Install Docker Engine

```shell
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

Optionally, manage Docker as a non-root user by following the instructions at [Manage Docker as a non-root user](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user).

```shell
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
```

Install Docker Compose 1.29.2

```shell
sudo curl -L "https://github.com/docker/compose/releases/download/v2.16.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
```

Clone the repository to your system:

```shell
git clone https://github.com/functionland/fula-ota
```

Install NetworkManager and set it to start automatically on boot
```shell
sudo systemctl start NetworkManager
sudo systemctl enable NetworkManager
```
### Automount

If your OS does not support auto-mounting you need to do this step. On raspberry pi, it is not needed as raspbian supports auto-mount, but on Armbian it is needed.

#### 1. Install dependencies

    sudo apt install net-tools dnsmasq-base rfkill git

#### 2. create automount script

``` shell
    sudo nano /usr/local/bin/automount.sh
```

And then fill it with:

```shell
    #!/bin/bash

    MOUNTPOINT="/media/pi"
    DEVICE="/dev/$1"
    MOUNTNAME=$(echo $1 | sed 's/[^a-zA-Z0-9]//g')
    mkdir -p ${MOUNTPOINT}/${MOUNTNAME}
    
    # Determine filesystem type
    FSTYPE=$(blkid -o value -s TYPE ${DEVICE})
    
    if [ ${FSTYPE} = "ntfs" ]; then
      # If filesystem is NTFS
      # uid and gid specify the owner and the group of files. 
      # dmask and fmask control the permissions for directories and files. 0000 gives everyone read and write access.
      mount -t ntfs -o uid=pi,gid=pi,dmask=0000,fmask=0000 ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
    elif [ ${FSTYPE} = "vfat" ]; then
      # If filesystem is FAT32
      mount -t vfat -o uid=pi,gid=pi,dmask=0000,fmask=0000 ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
    else
      # For other filesystem types
      mount ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
      # Changing owner for non-NTFS and non-FAT32 filesystems
      chown pi:pi ${MOUNTPOINT}/${MOUNTNAME}
    fi
```

And make it executable:

```shell
    sudo chmod +x /usr/local/bin/automount.sh
```

#### 3. create a service

##### 3.1. rules

``` shell
    sudo nano /etc/udev/rules.d/99-automount.rules
```

and fill it with:

```shell
    ACTION=="add", KERNEL=="sd[a-z][0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}="automount@%k.service"
    ACTION=="add", KERNEL=="nvme[0-9]n[0-9]p[0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}="automount@%k.service"
    
    ACTION=="remove", KERNEL=="sd[a-z][0-9]", RUN+="/bin/systemctl stop automount@%k.service"
    ACTION=="remove", KERNEL=="nvme[0-9]n[0-9]p[0-9]", RUN+="/bin/systemctl stop automount@%k.service"
```

##### 3.2 service

Create file:

```shell
    sudo nano /etc/systemd/system/automount@.service
```

 and add content:

```shell
    [Unit]
    Description=Automount disks
    BindsTo=dev-%i.device
    After=dev-%i.device
    
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/bin/automount.sh %I
    ExecStop=/usr/bin/sh -c '/bin/umount /media/pi/$(echo %I | sed 's/[^a-zA-Z0-9]//g'); /bin/rmdir /media/pi/$(echo %I | sed 's/[^a-zA-Z0-9]//g')'
```

And now restart the service with 

```shell
    sudo udevadm control --reload-rules
    sudo systemctl daemon-reload
```

And you can check the status of each service (that is created per attached device):

```shell
    systemctl status automount@sda1.service
```

### Install Fula OTA 

First install dependencies:

```shell
    sudo apt-get install gcc python3-dev python-is-python3 python3-pip
    sudo apt-get install python3-gi python3-gi-cairo gir1.2-gtk-3.0
    sudo apt install net-tools dnsmasq-base rfkill lshw
```

For board installation Navigate to the `fula` directory and give it permission to execute:

```shell
cd fula
sudo bash ./fula.sh rebuild
sudo bash ./fula.sh start
```

**THIS IS THE END OF INSTALLATION ON THE BOARD**

# Building Docker Images

If you want to build images and push to docker (not on the client) you can follow the below steps.

go to ```docker``` folder and run following commands

```shell
#for testing
#source env_test.sh
#for releasing
source env_release.sh
./build_and_push_images.sh
```

this command will push docker images into docker.io

## 📖 Script Commands Reference on rpi board

Command | Description
---------------------- | ------------------------------------
`install` | Start the installer.
`start` | Start all containers.
`restart`| Restart all containers (same as start).
`stop` | Stop all containers.
`rebuild`| Rebuild generated installation assets.
`update`| Pull latest docker images.
`help` | List all commands.
