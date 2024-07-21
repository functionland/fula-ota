document.addEventListener('DOMContentLoaded', async () => {
    const setupStarted = localStorage.getItem('setup_started');
    const walletSet = localStorage.getItem('wallet_set');
    const authorizerSet = localStorage.getItem('authorizer_set');
    const poolJoined = localStorage.getItem('pool_joined');

    if (!setupStarted || !walletSet || !authorizerSet || !poolJoined) {
        try {
            const seedResponse = await fetch('/api/account/seed');
            const idResponse = await fetch('/api/account/id');
            const seedData = await seedResponse.json();
            const idData = await idResponse.json();

            if (seedData.accountSeed && idData.accountId) {
                localStorage.setItem('setup_started', 'true');
                localStorage.setItem('wallet_set', 'true');
                localStorage.setItem('authorizer_set', 'true');
                window.location.href = '/webui/pools';
                return;
            }
        } catch (error) {
            console.error('Error fetching account data:', error);
        }
    }

    if (!setupStarted) {
        window.location.href = '/webui/welcome';
    } else if (!walletSet) {
        window.location.href = '/webui/connect-to-wallet';
    } else if (!authorizerSet) {
        window.location.href = '/webui/set-authorizer';
    } else if (!poolJoined) {
        window.location.href = '/webui/pools';
    } else {
        window.location.href = '/webui/home';
    }
});
