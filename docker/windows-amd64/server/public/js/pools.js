import axios from 'axios';
import { initApi, fetchPools, fetchUserPoolStatus, getSeed, joinPool, leavePool, cancelJoinPool } from './polkadot';

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

// Function to render the list of pools
function renderPools(pools, userStatus) {
    console.log('Rendering pools:', pools, 'User status:', userStatus); // Debug log
    const poolsList = document.getElementById('pools-list');
    poolsList.innerHTML = '';
    pools.forEach(pool => {
        const poolElement = document.createElement('div');
        poolElement.className = 'pool';
        const isMember = userStatus && userStatus.poolID == pool.poolID;
        const hasRequested = userStatus && userStatus.requestPoolId == pool.poolID;
        console.log({"userStatus.requestPoolId":userStatus.requestPoolId, "pool.poolID": pool.poolID, "hasRequested": hasRequested});

        poolElement.innerHTML = `
            <h3>${pool.name}</h3>
            <p>ID: ${pool.poolID}</p>
            <p>Location: ${pool.region}</p>
            <p id="status-${pool.poolID}" class="status-text"></p>
            ${isMember ? `<button class="button" onclick="leavePoolAction('${pool.poolID}')">Leave</button>` : ''}
            ${hasRequested ? `<button class="button" onclick="cancelJoinPoolAction('${pool.poolID}')">Cancel Join Request</button>` : ''}
            ${!isMember && !hasRequested ? `<button class="button" onclick="joinPoolAction('${pool.poolID}', '${pool.peerId}')">Join</button>` : ''}
        `;
        poolsList.appendChild(poolElement);
    });
}

async function updateUserStatus(api, accountId, pools) {
    const userStatus = await fetchUserPoolStatus(api, accountId);
    console.log('User status after fetch:', userStatus); // Debug log
    const goToHomeButton = document.getElementById('go-home-button');
    if (userStatus?.poolID) {
        renderPools(pools.pools, userStatus); // Accessing the pools array correctly
        goToHomeButton.classList.remove('disabled');
        goToHomeButton.disabled = false;
    } else if (userStatus?.requestPoolId) {
      console.log('User have a join request.');
      renderPools(pools.pools, userStatus);
    } else {
        console.log('User is not a member of any pool.');
        renderPools(pools.pools, {}); // Accessing the pools array correctly and passing an empty object
        goToHomeButton.classList.add('disabled');
        goToHomeButton.disabled = true;
    }
}

// Document ready event listener
document.addEventListener('DOMContentLoaded', async () => {
    const api = await initApi();
    const syncStatus = await axios.get('/api/chain/status');
    document.getElementById('sync-progress').textContent = syncStatus.data.syncProgress;
    document.getElementById('sync-progress-bar').value = syncStatus.data.syncProgress;
    if (syncStatus.data.syncProgress === 100) {
        document.getElementById('sync-status-section').style.display = 'none';
    }

    const pools = await fetchPools(api);
    console.log('Pools after fetch:', pools); // Debug log

    let accountId = localStorage.getItem('bloxAccountId');
    if (!accountId) {
        accountId = await axios.get('/api/account/id').then(response => response.data.accountId);
        if (!accountId) {
            alert('Failed to fetch account ID.');
            return;
        }
        localStorage.setItem('bloxAccountId', accountId);
    }

    await updateUserStatus(api, accountId, pools);

    document.getElementById('search-button').addEventListener('click', async () => {
        const searchQuery = document.getElementById('search-input').value.toLowerCase();
        const filteredPools = pools.pools.filter(pool => pool.name.toLowerCase().includes(searchQuery));
        renderPools(filteredPools, userStatus);
    });

    document.getElementById('refresh-status-button').addEventListener('click', async () => {
        await updateUserStatus(api, accountId, pools);
    });

    window.joinPoolAction = async (poolID, peerId) => {
        try {
            const seed = await getSeed();
            if (!seed) {
                alert("Could not get seed from backend");
                return;
            }

            const joinButton = document.querySelector(`button[onclick="joinPoolAction('${poolID}', '${peerId}')"]`);
            const refreshButton = document.getElementById('refresh-status-button');
            const statusText = document.getElementById(`status-${poolID}`);
            joinButton.disabled = true;
            joinButton.classList.add('disabled');
            refreshButton.disabled = true;
            statusText.textContent = 'Joining...';

            const response = await axios.post('/api/pools/join', { poolID, accountId });
            if (response.data.status === 'joined') {
                await joinPool(api, seed, poolID, peerId);
                await restartDockerContainers();
                await updateUserStatus(api, accountId, pools);
                statusText.textContent = 'Join request sent.';
            }
        } catch (error) {
            console.error('Error joining pool:', error);
        } finally {
            joinButton.disabled = false;
            joinButton.classList.remove('disabled');
            refreshButton.disabled = false;
        }
    };

    window.leavePoolAction = async (poolID) => {
        try {
            const seed = await getSeed();
            await leavePool(api, seed, poolID);
            await restartDockerContainers();
            await updateUserStatus(api, accountId, pools);
        } catch (error) {
            console.error('Error leaving pool:', error);
        }
    };

    window.cancelJoinPoolAction = async (poolID) => {
        try {
            const seed = await getSeed();
            await cancelJoinPool(api, seed, poolID);
            await restartDockerContainers();
            await updateUserStatus(api, accountId, pools);
        } catch (error) {
            console.error('Error canceling join pool:', error);
        }
    };

    setInterval(async () => {
        await updateUserStatus(api, accountId, pools);
    }, 300000); // Refresh status every 5 minutes
});
