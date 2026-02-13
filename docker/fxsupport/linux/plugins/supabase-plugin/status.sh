#!/bin/bash

set -e

SUPABASE_DIR="/opt/supabase"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "==========================================="
echo "Supabase Status"
echo "==========================================="

# Check if Supabase directory exists
if [ ! -d "$SUPABASE_DIR" ]; then
    echo -e "${RED}[ERROR]${NC} Supabase is not installed!"
    echo "Run './install.sh' first to install Supabase."
    exit 1
fi

cd $SUPABASE_DIR

# Check if services are running
echo -e "\n📊 Service Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if command -v docker &> /dev/null && docker compose version &> /dev/null 2>&1; then
    docker compose ps
else
    echo -e "${RED}[ERROR]${NC} Docker or Docker Compose not found!"
    exit 1
fi

# Get connection details from .env
if [ -f ".env" ]; then
    echo -e "\n🔗 Connection Details:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Extract values from .env safely using grep
    PUBLIC_IP=$(grep "^PUBLIC_IP=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    ANON_KEY=$(grep "^ANON_KEY=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    SERVICE_ROLE_KEY=$(grep "^SERVICE_ROLE_KEY=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    JWT_SECRET=$(grep "^JWT_SECRET=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    
    # Use defaults if not found
    PUBLIC_IP="${PUBLIC_IP:-localhost}"
    
    echo -e "${BLUE}Public IP:${NC} $PUBLIC_IP"
    echo ""
    
    echo -e "📡 ${GREEN}API Endpoints:${NC}"
    echo "• API URL: http://$PUBLIC_IP:8000"
    echo "• PostgreSQL: $PUBLIC_IP:5432"
    echo ""
    
    # Show API Keys if available
    if [ -n "$ANON_KEY" ] || [ -n "$SERVICE_ROLE_KEY" ]; then
        echo -e "🔑 ${GREEN}API Keys:${NC}"
        if [ -n "$ANON_KEY" ]; then
            echo "• Anon Key: ${ANON_KEY:0:20}..." # Show first 20 chars only
        fi
        if [ -n "$SERVICE_ROLE_KEY" ]; then
            echo "• Service Key: ${SERVICE_ROLE_KEY:0:20}..." # Show first 20 chars only
        fi
        echo ""
    fi
    
    # Show Database Credentials if available
    if [ -n "$POSTGRES_PASSWORD" ]; then
        echo -e "🔐 ${GREEN}Database Credentials:${NC}"
        echo "• Host: $PUBLIC_IP"
        echo "• Port: 5432"
        echo "• Database: postgres"
        echo "• Username: postgres"
        echo "• Password: ${POSTGRES_PASSWORD:0:10}..." # Show first 10 chars only
        echo ""
    fi
    
    # Check if credentials file exists
    if [ -f "credentials.txt" ]; then
        echo -e "📄 ${YELLOW}Full credentials available in:${NC}"
        echo "   cat $SUPABASE_DIR/credentials.txt"
        echo ""
    fi
 
    # Check service health
    echo -e "🏥 ${GREEN}Service Health:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Count running services
    RUNNING_COUNT=$(docker compose ps --format json 2>/dev/null | grep -c '"State":"running"' || echo "0")
    TOTAL_COUNT=$(docker compose ps --format json 2>/dev/null | wc -l || echo "0")
    
    if [ "$RUNNING_COUNT" -eq "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ All services are running ($RUNNING_COUNT/$TOTAL_COUNT)${NC}"
    elif [ "$RUNNING_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Some services are running ($RUNNING_COUNT/$TOTAL_COUNT)${NC}"
        echo "  Run './restart.sh' to restart all services"
    else
        echo -e "${RED}✗ No services are running${NC}"
        echo "  Run './start.sh' to start Supabase"
    fi
    
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found!"
    echo "Please run './install.sh' to set up Supabase."
    exit 1
fi

echo ""
echo "==========================================="
echo -e "${BLUE}Commands:${NC}"
echo "• Start:   ./start.sh"
echo "• Stop:    ./stop.sh"
echo "• Restart: ./restart.sh"
echo "• Logs:    docker compose logs -f"
echo "==========================================="