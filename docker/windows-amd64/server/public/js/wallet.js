import { HDKEY } from '@functionland/fula-sec-web';
import Web3 from 'web3';

document.addEventListener('DOMContentLoaded', () => {
    const passwordInput = document.getElementById('password-input');
    const iKnowCheckbox = document.getElementById('i-know-checkbox');
    const metamaskOpenCheckbox = document.getElementById('metamask-open-checkbox');
    const signMetamaskButton = document.getElementById('sign-metamask');
    const signManuallyButton = document.getElementById('sign-manually');
    const connectBloxButton = document.getElementById('connect-blox');
    //const reconnectBloxButton = document.getElementById('reconnect-blox');
    //const skipManualSetupButton = document.getElementById('skip-manual-setup');
    //const identitySection = document.getElementById('identity-section');
    //const identityText = document.getElementById('identity-text');
    
    let linking = false;
    let signatureData = '';
    let password = '';
    let signiture = '';

    // Utility function to update button states
    function updateButtonStates() {
        const isFormValid = passwordInput.value && iKnowCheckbox.checked && metamaskOpenCheckbox.checked;
        signMetamaskButton.disabled = !isFormValid;
        signManuallyButton.disabled = !isFormValid;
        signMetamaskButton.classList.toggle('disabled', !isFormValid);
        signManuallyButton.classList.toggle('disabled', !isFormValid);
    }

    async function personalSign(web3, msg) {
        console.log('personalSign');
        const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });

        console.log(accounts);
        console.log('getAccounts');
        if (!accounts || accounts.length === 0) {
            throw new Error('No accounts found. Please ensure MetaMask is connected.');
        }
        const account = accounts[0];
        console.log(`Signing message with account: ${account}`);
        const sign = await window.ethereum // Or window.ethereum if you don't support EIP-6963.
        .request({
            method: "personal_sign",
            params: [msg, account],
        });
        console.log(sign);
        return sign;
    }

    async function handleLinkPassword() {
        console.log('handleLinkPassword');
        try {
            if (linking) {
                linking = false;
                return;
            }
            linking = true;
            const passwordInputValue = passwordInput.value;
            const ed = new HDKEY(passwordInputValue);
            const chainCode = ed.chainCode;
            const msg = `Sign this message to link your wallet with the chain code: ${chainCode}`;
            const web3 = new Web3();
            const sig = await personalSign(web3, msg);
            if (!sig) {
                throw new Error('Sign failed');
            }
            console.log(sig);
            signatureData = sig;
            password = passwordInputValue;
            saveCredentials(password, signatureData);
            //identitySection.style.display = 'block';
            localStorage.setItem('wallet_set', 'true');
            window.location.href = '/webui/set-authorizer';
        } catch (err) {
            console.error('Error:', err);
            alert('Unable to sign the wallet address! Make sure MetaMask is connected and you have an account selected.');
        } finally {
            linking = false;
        }
    }

    // Save credentials securely
    function saveCredentials(password, signatureData) {
        const credentials = {
            password,
            signatureData
        };
        localStorage.setItem('credentials', JSON.stringify(credentials));
    }

    // Retrieve credentials securely
    function getCredentials() {
        const credentials = localStorage.getItem('credentials');
        if (credentials) {
            return JSON.parse(credentials);
        }
        return null;
    }

    /*function updateIdentity(password, signatureData) {
        const did = getMyDID(password, signatureData);
        identityText.textContent = did;
        connectBloxButton.style.display = 'block';
        reconnectBloxButton.style.display = 'block';
        skipManualSetupButton.style.display = 'block';
    }*/

    /*function getMyDID(password, signature) {
        // Dummy function, replace with actual logic to generate DID
        return `DID:${password}:${signature}`;
    }*/

    passwordInput.addEventListener('input', updateButtonStates);
    iKnowCheckbox.addEventListener('change', updateButtonStates);
    metamaskOpenCheckbox.addEventListener('change', updateButtonStates);

    signMetamaskButton.addEventListener('click', async () => {
        if (!passwordInput.value || !iKnowCheckbox.checked || !metamaskOpenCheckbox.checked) {
            alert('Please complete all required fields and checkboxes.');
            return;
        }
        await handleLinkPassword();
    });

    signManuallyButton.addEventListener('click', () => {
        if (!passwordInput.value || !iKnowCheckbox.checked) {
            alert('Please complete all required fields and checkboxes.');
            return;
        }
        const sig = prompt('Enter your signature:');
        if (sig) {
            signatureData = sig;
            saveCredentials(passwordInput.value, sig);
            //updateIdentity(passwordInput.value, sig);
            localStorage.setItem('wallet_set', 'true');
            window.location.href = '/webui/set-blox-authorizer';
        }
    });

    connectBloxButton.addEventListener('click', () => {
        window.location.href = '/webui/connect-to-blox';
    });

    /*reconnectBloxButton.addEventListener('click', () => {
        window.location.href = '/webui/connect-to-existing-blox';
    });

    skipManualSetupButton.addEventListener('click', () => {
        window.location.href = '/webui/set-blox-authorizer';
    });*/

    // Initial button state update
    updateButtonStates();
});
