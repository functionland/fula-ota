
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
### Install Usbmount

#### 1. Install dependencies

    sudo apt install git debhelper build-essential ntfs-3g

#### 2. compile and install usbmount

    cd /tmp
    git clone https://github.com/rbrito/usbmount.git
    cd usbmount
    dpkg-buildpackage -us -uc -b
    cd ..
    sudo apt install ./usbmount_0.0.24_all.deb

#### 3. edit configuration

##### 3.1. usbmount

``` shell
    sudo nano /etc/usbmount/usbmount.conf
```

and change these keys to:

```shell
    MOUNTPOINTS="/media/pi/usb0 /media/pi/usb1 /media/pi/usb2 /media/pi/usb3
                 /media/pi/usb4 /media/pi/usb5 /media/pi/usb6 /media/pi/usb7"
    FILESYSTEMS="vfat ext2 ext3 ext4 hfsplus ntfs fuseblk"
    VERBOSE=yes
```

##### 3.2 udev

Create file:

```shell
    sudo mkdir /etc/systemd/system/systemd-udevd.service.d
    sudo nano -w /etc/systemd/system/systemd-udevd.service.d/00-my-custom-mountflags.conf
```

 and add content:

```shell
    [Service]
    PrivateMounts=no
```

### Install Fula OTA 
For board installation Navigate to the `fula` directory and give it permission to execute:

```shell
cd fula && chmod +x *
sudo ./fula.sh rebuild
sudo ./fula.sh start
```

# Building Docker Images

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
