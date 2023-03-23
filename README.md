
FxLand OTA based on docker solution

### Linux

Install Docker Engine 20.10

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
# Running the docker on end device

Install NetworkManager and set it to start automatically on boot
```shell
sudo systemctl start NetworkManager
sudo systemctl enable NetworkManager
```

For board installation Navigate to the `fula` directory and give it permission to execute:

```shell
cd fula && chmod +x *
sudo ./fula.sh rebuild
sudo ./fula.sh start
```
## 📖 Script Commands Reference on rpi board

Command | Description
---------------------- | ------------------------------------
`install` | Start the installer.
`start` | Start all containers.
`restart`	| Restart all containers (same as start).
`stop` | Stop all containers.
`rebuild`	| Rebuild generated installation assets.
`help` | List all commands.


# Building Docker Images

go to ```docker``` folder and run following commands

```shell
./build_and_push_images.sh
```

this command will push docker images into docker.io
