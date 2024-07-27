import { createWeb3Modal, defaultWagmiConfig } from '@web3modal/wagmi'
import { createConfig, getAccount, reconnect, signMessage } from '@wagmi/core'
import { mainnet, arbitrum } from 'viem/chains'
import { metaMask } from '@wagmi/connectors'
import { http } from 'viem'
import { HDKEY } from '@functionland/fula-sec-web';

// WalletConnect project ID
const projectId = '94a4ca39db88ee0be8f6df95fdfb560a';
const metadata = {
    name: 'FxBlox',
    description: 'Application to set up FxBlox, designed to run as a Decentralized Physical Infrastructure node (DePIN)',
    url: 'https://web3modal.com', // origin must match your domain & subdomain
    icons: ['https://imagedelivery.net/_aTEfDRm7z3tKgu9JhfeKA/1f36e0e1-df9a-4bdc-799b-8631ab1eb000/sm']
};

const chains = [mainnet, arbitrum];
const metaMaskConnector = metaMask({ chains });

const config = defaultWagmiConfig({
    chains,
    projectId,
    metadata,
    connectors: [metaMaskConnector],
    transports: {
        [mainnet.id]: http(),
        [arbitrum.id]: http(),
    },
});
//await reconnect(config);
// Create Web3Modal
const modal = createWeb3Modal({
    wagmiConfig: config,
    projectId,
    enableAnalytics: true, // Optional - defaults to your Cloud configuration
    enableOnramp: true // Optional - false as default
});

document.addEventListener('DOMContentLoaded', () => {
    const passwordInput = document.getElementById('password-input');
    const iKnowCheckbox = document.getElementById('i-know-checkbox');
    const metamaskOpenCheckbox = document.getElementById('metamask-open-checkbox');
    const signMetamaskButton = document.getElementById('sign-metamask');
    const signManuallyButton = document.getElementById('sign-manually');
    const connectBloxButton = document.getElementById('connect-blox');
    
    let linking = false;
    let signatureData = '';
    let password = '';

    function updateButtonStates() {
        const isFormValid = passwordInput.value && iKnowCheckbox.checked && metamaskOpenCheckbox.checked;
        signMetamaskButton.disabled = !isFormValid;
        signManuallyButton.disabled = !isFormValid;
        signMetamaskButton.classList.toggle('disabled', !isFormValid);
        signManuallyButton.classList.toggle('disabled', !isFormValid);
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

            const signature = await signMessage(config, { message: msg });

            if (!signature) {
                throw new Error('Sign failed');
            }
            console.log(signature);
            signatureData = signature;
            password = passwordInputValue;
            saveCredentials(password, signatureData);
            localStorage.setItem('wallet_set', 'true');
            window.location.href = '/webui/set-authorizer';
        } catch (err) {
            console.error('Error:', err);
            alert('Unable to sign the message! Make sure your wallet is connected and you have an account selected.');
        } finally {
            linking = false;
        }
    }

    function saveCredentials(password, signatureData) {
        const credentials = { password, signatureData };
        localStorage.setItem('credentials', JSON.stringify(credentials));
    }

    function getCredentials() {
        const credentials = localStorage.getItem('credentials');
        return credentials ? JSON.parse(credentials) : null;
    }

    passwordInput.addEventListener('input', updateButtonStates);
    iKnowCheckbox.addEventListener('change', updateButtonStates);
    metamaskOpenCheckbox.addEventListener('change', updateButtonStates);

    modal.subscribeEvents(event => {
        console.log(event.data.event);
        const state = event?.data?.event;
        if (state == "CONNECT_SUCCESS") {
            console.log('connectd to wallet');
            const account = getAccount(config);
            const address = account?.address;
            console.log('logged in with address: ' + address);
            if (address) {
                handleLinkPassword();
            }
        }
    
    });
    signMetamaskButton.addEventListener('click', async () => {
        if (!passwordInput.value || !iKnowCheckbox.checked || !metamaskOpenCheckbox.checked) {
            alert('Please complete all required fields and checkboxes.');
            return;
        }
        
        try {
            console.log('connect');
            modal.close();
            modal.open({ view: 'Connect' }).then((res) => {
                console.log('res received');
                console.log(res);
            });
        } catch (error) {
            console.error('Connection error:', error);
            alert('Failed to connect wallet. Please try again.');
        }
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
            localStorage.setItem('wallet_set', 'true');
            window.location.href = '/webui/set-blox-authorizer';
        }
    });

    connectBloxButton.addEventListener('click', () => {
        window.location.href = '/webui/connect-to-blox';
    });

    updateButtonStates();
});
