import axios from 'axios';
import { initApi, fetchUserPoolStatus } from './polkadot';

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

// Function to update hard disk information
const updateHardDiskInfo = async (api) => {
    const hardDiskCard = document.getElementById('hard-disk-card');
    const capacityElem = hardDiskCard.querySelector('#capacity');
    const fulaSizeElem = hardDiskCard.querySelector('#fula-size');
    const chainSizeElem = hardDiskCard.querySelector('#chain-size');
    const usedElem = hardDiskCard.querySelector('#used');
    const freeElem = hardDiskCard.querySelector('#free');
    const statusElem = hardDiskCard.querySelector('#status');

    // Simulating data fetching
    capacityElem.textContent = convertByteToCapacityUnit(1024 * 1024 * 500); // 500 MB
    fulaSizeElem.textContent = convertByteToCapacityUnit(1024 * 1024 * 100); // 100 MB
    chainSizeElem.textContent = convertByteToCapacityUnit(1024 * 1024 * 50); // 50 MB
    usedElem.textContent = convertByteToCapacityUnit(1024 * 1024 * 300); // 300 MB
    freeElem.textContent = convertByteToCapacityUnit(1024 * 1024 * 200); // 200 MB
    statusElem.textContent = 'In Use';
};

// Function to update earnings information
const updateEarningsInfo = async (api, accountId) => {
    const earningsCard = document.getElementById('earnings-card');
    const totalFulaElem = earningsCard.querySelector('#total-fula');

    // Simulating data fetching
    totalFulaElem.textContent = '123.456'; // Simulating total fula earnings
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

    await updateHardDiskInfo(api);
    await updateEarningsInfo(api, accountId);

    document.getElementById('refresh-disk-button').addEventListener('click', async () => {
        await updateHardDiskInfo(api);
    });

    document.getElementById('refresh-earnings-button').addEventListener('click', async () => {
        await updateEarningsInfo(api, accountId);
    });

    document.getElementById('go-home-button').addEventListener('click', () => {
        window.location.href = '/home.html';
    });

    const refreshStatusButton = document.getElementById('refresh-status-button');
    refreshStatusButton.disabled = true;

    const goHomeButton = document.getElementById('go-home-button');
    goHomeButton.disabled = true;
    goHomeButton.classList.add('disabled');

    const checkUserStatus = async () => {
        const userStatus = await fetchUserPoolStatus(api, accountId);
        console.log('User status after fetch:', userStatus); // Debug log
        if (userStatus.poolID) {
            goHomeButton.disabled = false;
            goHomeButton.classList.remove('disabled');
        } else {
            goHomeButton.disabled = true;
            goHomeButton.classList.add('disabled');
        }
    };

    setInterval(async () => {
        await checkUserStatus();
    }, 300000); // Refresh status every 5 minutes

    refreshStatusButton.addEventListener('click', async () => {
        await checkUserStatus();
    });

    await checkUserStatus();
};

document.addEventListener('DOMContentLoaded', setupHomePage);
