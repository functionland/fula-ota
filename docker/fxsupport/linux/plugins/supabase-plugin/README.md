# Supabase Plugin for FxSupport

## Overview
This plugin enables you to run Supabase, an open-source Firebase alternative, on your FxSupport system using Docker containers.

## Features
- **PostgreSQL Database**: Full-featured PostgreSQL database
- **Authentication**: Built-in user authentication and authorization
- **Instant APIs**: Auto-generated REST and GraphQL APIs
- **Realtime Subscriptions**: Listen to database changes in real-time
- **Storage**: Store and serve files
- **Edge Functions**: Deploy serverless functions
- **Studio Dashboard**: Web-based database management interface

## Requirements
- Linux OS (x86_64 or ARM64)
- Minimum 2GB RAM (4GB recommended)
- 10GB available disk space
- Docker 20.10.0 or higher

## Installation
```bash
./install.sh
```
This will:
- Check system requirements
- Install Docker if not present
- Download Supabase Docker images
- Configure environment variables
- Set up firewall rules

## Usage

### Start Supabase
```bash
./start.sh
```

### Stop Supabase
```bash
./stop.sh
```

### Restart Supabase
```bash
./restart.sh
```

### Check Status
```bash
./status.sh
```
This displays:
- Service status
- Connection URLs
- API keys
- Database credentials

### Uninstall
```bash
./uninstall.sh
```
**Warning**: This removes all data and configurations!

## Access Points

After starting, Supabase will be available at:
- **API Gateway**: http://YOUR_PUBLIC_IP:8000
- **PostgreSQL**: YOUR_PUBLIC_IP:5432


## Security Considerations

1. **Change default passwords**: Update all default credentials after installation
2. **Configure SSL**: For production use, set up SSL certificates
3. **Firewall rules**: Ensure only necessary ports are exposed
4. **API Keys**: Keep your service keys secure and never expose them publicly

## Network Configuration

The plugin automatically:
- Detects your public IP address
- Configures Supabase to be accessible externally
- Opens required firewall ports (if UFW is installed)

## Troubleshooting

### Services not starting
```bash
docker compose logs -f
```

### Reset configuration
```bash
./stop.sh
cd /opt/supabase
rm .env
./install.sh
```

### Check Docker status
```bash
docker ps
docker compose ps
```

## Support

For issues related to:
- **This plugin**: Create an issue in the FxSupport repository
- **Supabase**: Visit https://supabase.com/docs

## License
MIT License

## Directory Structure

```
supabase-plugin/
├── install.sh
├── start.sh
├── stop.sh
├── restart.sh
├── uninstall.sh
├── status.sh
├── info.json
└── README.md
```

## Installation Instructions
1. Create a directory called `supabase-plugin`
2. Save all the above files in that directory
3. Make scripts executable: `chmod +x *.sh`
4. Run installation: `./install.sh`