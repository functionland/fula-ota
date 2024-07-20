import axios from 'axios';
import { createSeed } from './peer-id-utils';

// Function to fetch saved credentials from local storage
function getCredentials() {
    const credentials = localStorage.getItem('credentials');
    if (credentials) {
        return JSON.parse(credentials);
    }
    return null;
}

// Function to check if the peer IDs are already saved in local storage
function checkPeerIds() {
    const appPeerId = localStorage.getItem('appPeerId');
    const bloxPeerId = localStorage.getItem('bloxPeerId');
    return appPeerId && bloxPeerId;
}

// Function to generate the peer ID and handle the next steps
async function handleExchange() {
    try {
        const credentials = getCredentials();
        if (!credentials) {
            throw new Error('Missing saved credentials. Please go back and sign in again.');
        }

        const { password, signatureData } = credentials;
        console.log({ password, signatureData });
        const seed = createSeed(signatureData, password);
        console.log({ seed });

        // Call the new endpoint to get the peer ID
        const response = await axios.post('/api/peer/generate-identity', { seed });
        const { peer_id, seed: generatedSeed } = response.data;

        console.log('Generated Peer ID:', peer_id);

        // Update the UI with the new peer ID
        document.getElementById('new-peer-id-text').textContent = peer_id;

        // Exchange config with blox
        const bloxPeerId = await exchangeConfig(peer_id, generatedSeed);

        console.log('Blox Peer ID:', bloxPeerId);

        // Update the UI with the new blox peer ID
        document.getElementById('new-blox-peer-id-text').textContent = bloxPeerId;

        // Save peer IDs in local storage
        localStorage.setItem('bloxPeerId', bloxPeerId);
        localStorage.setItem('appPeerId', peer_id);

        // Enable the Next button
        const nextButton = document.getElementById('next-button');
        nextButton.disabled = false;
        nextButton.classList.remove('disabled');
    } catch (error) {
        console.error('Error:', error);
        alert(`Error: ${error.message}`);
    }
}

// Function to exchange config with blox
async function exchangeConfig(peerId, seed) {
    try {
        const response = await axios.post('/api/peer/exchange', { PeerID: peerId, seed: seed });
        const peerIdMatch = response.data.peer_id.match(/12D\w+/);
        if (!peerIdMatch) {
            throw new Error('Peer ID format is incorrect');
        }
        return peerIdMatch[0];
    } catch (error) {
        throw new Error(`Failed to exchange config: ${error.message}`);
    }
}

async function handleNext() {
    try {
        // Redirect to the setup complete page
        window.location.href = '/webui/pools';
    } catch (error) {
        console.error('Error:', error);
        alert(`Error: ${error.message}`);
    }
}

// Document ready event listener
document.addEventListener('DOMContentLoaded', () => {
    const nextButton = document.getElementById('next-button');
    const exchangeButton = document.getElementById('set-authorizer-button');

    if (checkPeerIds()) {
        // Peer IDs are already saved, disable the Set Authorizer button and enable the Next button
        exchangeButton.disabled = true;
        exchangeButton.classList.add('disabled');
        nextButton.disabled = false;
        nextButton.classList.remove('disabled');

        // Update the UI with the saved peer IDs
        const appPeerId = localStorage.getItem('appPeerId');
        const bloxPeerId = localStorage.getItem('bloxPeerId');
        document.getElementById('new-peer-id-text').textContent = appPeerId;
        document.getElementById('new-blox-peer-id-text').textContent = bloxPeerId;
    } else {
        // Peer IDs are not saved, disable the Next button and enable the Set Authorizer button
        nextButton.disabled = true;
        nextButton.classList.add('disabled');
    }

    exchangeButton.addEventListener('click', handleExchange);
    nextButton.addEventListener('click', handleNext);
});
