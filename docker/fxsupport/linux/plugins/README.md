## Plugins

Plugins are separate services that can be added to a blox and users can opt-in to run them

## How to add a plugin

1- Each plugin has a name that should be the same as service name and runs in its own docker
2- Each plugin need these 4 files:
- install.sh: which installs the service nad dependencies
- start.sh: which starts the service
- stop.sh: which stops the service
- {name}.service: which is the service file itself
- uninstall.sh: which uninstalls and removes the service and associated files
- docker-compose.yml: which is the configuration of docker running the plugin

User can activate or deactivate plugins and active plugins are stored in /home/pi/active-plugins.txt

## Current Plugins

- streamr-node: This plugin runs a streamr node on the blox and can earn $DATA