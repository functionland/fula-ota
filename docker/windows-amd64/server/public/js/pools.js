import axios from 'axios';

// Function to fetch pools from the API
async function fetchPools() {
    try {
        const response = await axios.post(
            'https://api.node3.functionyard.fula.network/fula/pool',
            {},
            {
                headers: {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*',
                    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
                    'Access-Control-Allow-Headers': 'Content-Type'
                }
            }
        );
        return response.data.pools;
    } catch (error) {
        console.error('Error fetching pools:', error);
        return [];
    }
}


// Function to fetch user pool status
async function fetchUserPoolStatus(accountId) {
    try {
        const response = await axios.post(
            'https://api.node3.functionyard.fula.network/fula/pool/users',
            { account: accountId },
            { headers: { 'Content-Type': 'application/json' } }
        );
        return response.data.users[0];
    } catch (error) {
        console.error('Error fetching user pool status:', error);
        return null;
    }
}

// Function to fetch account ID from the API
async function fetchAccountId() {
    try {
        const response = await axios.get('/api/account/id');
        return response.data.accountId;
    } catch (error) {
        console.error('Error fetching account ID:', error);
        return null;
    }
}

// Function to restart Docker containers
async function restartDockerContainers() {
    const containers = ['ipfs_host', 'ipfs_cluster', 'fula_go', 'fula_node'];
    for (const container of containers) {
        try {
            await axios.post('/api/docker/restart', { container });
            console.log(`Successfully restarted ${container}`);
        } catch (error) {
            console.error(`Error restarting ${container}:`, error);
        }
    }
}

// Function to join a pool
async function joinPool(poolID) {
    try {
        const accountId = localStorage.getItem('bloxAccountId');
        const response = await axios.post('/api/pools/join', { poolID, accountId });
        if (response.data.status === 'joined') {
            await restartDockerContainers();
        }
        return response.data;
    } catch (error) {
        console.error('Error joining pool:', error);
    }
}

// Function to leave a pool
async function leavePool(poolID) {
    try {
        const accountId = localStorage.getItem('bloxAccountId');
        const response = await axios.post('/api/pools/leave', { poolID, accountId });
        return response.data;
    } catch (error) {
        console.error('Error leaving pool:', error);
    }
}

// Function to cancel a join request
async function cancelJoinPool(poolID) {
    try {
        const accountId = localStorage.getItem('bloxAccountId');
        const response = await axios.post('/api/pools/cancel', { poolID, accountId });
        return response.data;
    } catch (error) {
        console.error('Error canceling join pool:', error);
    }
}

// Function to check chain sync status
async function checkChainSyncStatus() {
    try {
        const response = await axios.get('/api/chain/status');
        return response.data;
    } catch (error) {
        console.error('Error checking chain sync status:', error);
        return { isSynced: false, syncProgress: 0 };
    }
}

// Function to render the list of pools
function renderPools(pools, userStatus) {
    const poolsList = document.getElementById('pools-list');
    poolsList.innerHTML = '';
    pools.forEach(pool => {
        const poolElement = document.createElement('div');
        poolElement.className = 'pool';
        const isMember = userStatus.pool_id === pool.pool_id;
        const hasRequested = userStatus.request_pool_id === pool.pool_id;

        poolElement.innerHTML = `
            <h3>${pool.pool_name}</h3>
            <p>ID: ${pool.pool_id}</p>
            <p>Location: ${pool.region}</p>
            ${isMember ? `<button onclick="leavePool('${pool.pool_id}')">Leave</button>` : ''}
            ${hasRequested ? `<button onclick="cancelJoinPool('${pool.pool_id}')">Cancel Join Request</button>` : ''}
            ${!isMember && !hasRequested ? `<button onclick="joinPool('${pool.pool_id}')">Join</button>` : ''}
        `;
        poolsList.appendChild(poolElement);
    });
}

// Document ready event listener
document.addEventListener('DOMContentLoaded', async () => {
    const syncStatus = await checkChainSyncStatus();
    document.getElementById('sync-progress').textContent = syncStatus.syncProgress;
    document.getElementById('sync-progress-bar').value = syncStatus.syncProgress;

    const pools = await fetchPools();

    let accountId = localStorage.getItem('bloxAccountId');
    if (!accountId) {
        accountId = await fetchAccountId();
        if (!accountId) {
            alert('Failed to fetch account ID.');
            return;
        }
        localStorage.setItem('bloxAccountId', accountId);
    }

    const userStatus = await fetchUserPoolStatus(accountId);
    if (userStatus) {
        renderPools(pools, userStatus);
    } else {
        console.error('Failed to fetch user pool status.');
    }

    document.getElementById('search-button').addEventListener('click', async () => {
        const searchQuery = document.getElementById('search-input').value.toLowerCase();
        const filteredPools = pools.filter(pool => pool.pool_name.toLowerCase().includes(searchQuery));
        renderPools(filteredPools, userStatus);
    });
});
