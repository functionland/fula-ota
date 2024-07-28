import axios from 'axios';
import { initApi, fetchPools, fetchUserPoolStatus, getSeed, joinPool, leavePool, cancelJoinPool } from './polkadot';

let globalUserStatus;

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
    console.log('Rendering pools:', pools, 'User status:', userStatus);
    const poolsList = document.getElementById('pools-list');
    poolsList.innerHTML = '';
    pools.forEach(pool => {
        const poolElement = document.createElement('div');
        poolElement.className = 'pool';
        const isMember = userStatus && userStatus.poolId == pool.poolID;
        const hasRequested = userStatus && userStatus.requestPoolId == pool.poolID;
        console.log({"userStatus.requestPoolId":userStatus.requestPoolId, "userStatus.poolID":userStatus.poolID, "pool.poolID": pool.poolID, "hasRequested": hasRequested, "isMember": isMember});

        poolElement.innerHTML = `
            <h3>${pool.name}</h3>
            <p>ID: ${pool.poolID}</p>
            <p>Location: ${pool.region}</p>
            <p id="status-${pool.poolID}" class="status-text"></p>
            ${isMember ? `<button class="button" id="leave-pool-${pool.poolID}" onclick="leavePoolAction('${pool.poolID}')">Leave</button>` : ''}
            ${hasRequested ? `<button class="button" id="cancel-join-${pool.poolID}" onclick="cancelJoinPoolAction('${pool.poolID}')">Cancel Join Request</button>` : ''}
            ${!isMember && !hasRequested ? `<button class="button" id="join-pool-${pool.poolID}" onclick="joinPoolAction('${pool.poolID}')">Join</button>` : ''}
        `;
        poolsList.appendChild(poolElement);
    });
}

function renderInfoBox(accountId) {
    const infoBox = document.getElementById('info-box');
    const accountIdElement = document.getElementById('blox-account-id');
    accountIdElement.textContent = accountId;
    infoBox.style.display = 'block';

    // Remove existing event listener before adding a new one
    accountIdElement.removeEventListener('click', copyAccountId);
    accountIdElement.addEventListener('click', copyAccountId);
}

function copyAccountId() {
    const accountId = this.textContent;
    navigator.clipboard.writeText(accountId)
        .then(() => {
            alert('Account ID copied to clipboard');
        })
        .catch(err => {
            console.error('Could not copy text: ', err);
        });
}


async function updateUserStatus(api, accountId, pools) {
    const userStatus = await fetchUserPoolStatus(api, accountId);
    globalUserStatus = userStatus;
    console.log('User status after fetch:', userStatus); // Debug log
    const goToHomeButton = document.getElementById('go-home-button');
    if (userStatus?.poolId) {
        renderPools(pools.pools, userStatus); // Accessing the pools array correctly
        goToHomeButton.classList.remove('disabled');
        goToHomeButton.disabled = false;
        localStorage.setItem('pool_joined', 'true');
    } else if (userStatus?.requestPoolId) {
      console.log('User have a join request.');
      renderPools(pools.pools, userStatus);
      goToHomeButton.classList.remove('disabled');
      goToHomeButton.disabled = false;
      localStorage.setItem('pool_joined', 'true');
    } else {
        console.log('User is not a member of any pool.');
        renderPools(pools.pools, {}); // Accessing the pools array correctly and passing an empty object
        goToHomeButton.classList.add('disabled');
        goToHomeButton.disabled = true;
    }
    renderInfoBox(accountId);
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

    window.joinPoolAction = async (poolID) => {
        try {
            const userStatus = await fetchUserPoolStatus(api, accountId);
            if (userStatus?.poolId) {
                alert("You are already a member of a pool. Please leave your current pool before joining a new one.");
                return;
            }
            if (userStatus?.requestPoolId) {
                alert("You already have an active join request. Please cancel it before joining a new pool.");
                return;
            }
            const peerId = localStorage.getItem('bloxPeerId');
            if (!peerId) {
                window.location.href = '/webui/set-authorizer';
                return;
            }
            console.log('blox peerId:'+peerId);
                
            const seed = await getSeed();
            if (!seed) {
                alert("Could not get seed from backend");
                return;
            }
    
            const joinButton = document.getElementById(`join-pool-${poolID}`);
            const allButtons = document.querySelectorAll('.button');
            
            // Disable all buttons
            allButtons.forEach(button => {
                button.disabled = true;
                //button.className.add('disabled');
            });
            
            // Change text of the clicked button
            joinButton.textContent = 'Joining...';
    
            const response = await axios.post('/api/pools/join', { poolID, accountId });
            if (response.data.status === 'joined') {
                await joinPool(api, seed, poolID, peerId);
                await restartDockerContainers();
                await updateUserStatus(api, accountId, pools);
            }
        } catch (error) {
            console.error('Error joining pool:', error);
        } finally {
            // Re-enable all buttons and revert text
            const allButtons = document.querySelectorAll('.button');
            allButtons.forEach(button => {
                button.disabled = false;
                //button.className.remove('disabled');
            });
            const joinButton = document.getElementById(`join-pool-${poolID}`);
            if (joinButton) {
                joinButton.textContent = 'Join';
            }
        }
    };

    window.leavePoolAction = async (poolID) => {
        try {
            const leaveButton = document.getElementById(`leave-pool-${poolID}`);
            const allButtons = document.querySelectorAll('.button');
            
            // Disable all buttons
            allButtons.forEach(button => button.disabled = true);
            
            // Change text of the clicked button
            leaveButton.textContent = 'Leaving pool...';
            
            const seed = await getSeed();
            await leavePool(api, seed, poolID);
            await restartDockerContainers();
            await updateUserStatus(api, accountId, pools);
        } catch (error) {
            console.error('Error leaving pool:', error);
        } finally {
            // Re-enable all buttons and revert text
            const allButtons = document.querySelectorAll('.button');
            allButtons.forEach(button => button.disabled = false);
            const leaveButton = document.getElementById(`leave-pool-${poolID}`);
            if (leaveButton) {
                leaveButton.textContent = 'Leave';
            }
        }
    };

    window.cancelJoinPoolAction = async (poolID) => {
        try {
            const cancelButton = document.getElementById(`cancel-join-${poolID}`);
            const allButtons = document.querySelectorAll('.button');
            
            // Disable all buttons
            allButtons.forEach(button => button.disabled = true);
            
            // Change text of the clicked button
            cancelButton.textContent = 'Cancelling the request...';
            
            const seed = await getSeed();
            await cancelJoinPool(api, seed, poolID);
            await restartDockerContainers();
            await updateUserStatus(api, accountId, pools);
        } catch (error) {
            console.error('Error canceling join pool:', error);
        } finally {
            // Re-enable all buttons and revert text
            const allButtons = document.querySelectorAll('.button');
            allButtons.forEach(button => button.disabled = false);
            const cancelButton = document.getElementById(`cancel-join-${poolID}`);
            if (cancelButton) {
                cancelButton.textContent = 'Cancel Join Request';
            }
        }
    };

    document.getElementById('go-home-button').addEventListener('click', () => {
      window.location.href = '/webui/home';
    });

    setInterval(async () => {
        await updateUserStatus(api, accountId, pools);
    }, 300000); // Refresh status every 5 minutes
});
