import axios from 'axios';
import { initApi } from './polkadot';

// Utility function to convert bytes to a more readable unit
const convertByteToCapacityUnit = (bytes) => {
    if (bytes < 1024) return `${bytes} B`;
    const units = ['KB', 'MB', 'GB', 'TB'];
    let unitIndex = -1;
    do {
        bytes /= 1024;
        unitIndex++;
    } while (bytes >= 1024);
    return `${bytes.toFixed(2)} ${units[unitIndex]}`;
};

// Function to check Docker status
const checkDockerStatus = async (dockerName) => {
    try {
        const response = await axios.get(`/api/docker/status?name=${dockerName}`);
        return response.data;
    } catch (error) {
        console.error(`Error checking status for ${dockerName}:`, error);
        return { status: 'not running' };
    }
};

// Function to update Docker information
const updateDockerInfo = async () => {
    const dockerNames = ['fula_go', 'fula_node', 'ipfs_host', 'ipfs_cluster', 'fula_fxsupport'];
    for (const dockerName of dockerNames) {
        const statusElement = document.getElementById(`${dockerName}-status`);
        const hintElement = document.getElementById(`${dockerName}-hint`);
        statusElement.innerHTML = '<div class="loading-spinner"></div>'; // Show loading spinner
        try {
            const status = await checkDockerStatus(dockerName);
            statusElement.textContent = status.status;
            if (status.status === 'Error') {
                hintElement.style.display = 'inline';
                hintElement.setAttribute('title', status.errorLine);
            } else {
                hintElement.style.display = 'none';
            }
        } catch (error) {
            statusElement.textContent = 'Error checking status';
            hintElement.style.display = 'none';
        }
    }
};

// Function to update earnings information
const updateEarningsInfo = async (api, accountId) => {
    try {
        const earnings = await api.query.asset.balances(accountId, 100, 100);
        document.getElementById('total-fula').textContent = earnings.toHuman();
    } catch (error) {
        console.error('Error updating earnings info:', error);
        document.getElementById('total-fula').textContent = '0';
    }
};

const setupHomePage = async () => {
    const api = await initApi();
    let accountId = localStorage.getItem('bloxAccountId');
    if (!accountId) {
        accountId = await axios.get('/api/account/id').then(response => response.data.accountId);
        if (!accountId) {
            alert('Failed to fetch account ID.');
            return;
        }
        localStorage.setItem('bloxAccountId', accountId);
    }

    await updateDockerInfo();
    await updateEarningsInfo(api, accountId);

    document.getElementById('refresh-disk-button').addEventListener('click', async () => {
        await updateDockerInfo();
    });

    document.getElementById('refresh-earnings-button').addEventListener('click', async () => {
        await updateEarningsInfo(api, accountId);
    });

    document.getElementById('go-pools-button').addEventListener('click', () => {
        window.location.href = '/webui/pools';
    });
};

document.addEventListener('DOMContentLoaded', setupHomePage);
