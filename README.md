
FxLand OTA based on docker solution

### Linux

Install Docker Engine 20.10

```shell
curl -fsSL https://get.docker.com -o get-docker.sh
sudo VERSION=20.10 sh get-docker.sh
```

Optionally, manage Docker as a non-root user by following the instructions at [Manage Docker as a non-root user](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user).

```shell
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
```

Install Docker Compose 1.29.2

```shell
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
```

Clone the repository to your system:

```shell
git clone https://github.com/smzahraee/fula-ota
```

Navigate to the `scripts` directory and give it permission to execute:

```shell
cd scripts && chmod +x *
```

Run the installation script. A `./fula-linux.sh` directory will be created.

```shell
./fula-linux.sh install 
```

Finally, start your IoT Portal instance.

```shell
./fula-linux.sh start 
```

## 📖 Script Commands Reference

Command | Description
---------------------- | ------------------------------------
`install` | Start the installer.
`start` | Start all containers.
`restart`	| Restart all containers (same as start).
`stop` | Stop all containers.
`rebuild`	| Rebuild generated installation assets.
`help` | List all commands.
