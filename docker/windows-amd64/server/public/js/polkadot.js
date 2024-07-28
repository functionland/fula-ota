const { ApiPromise, WsProvider } = require('@polkadot/api');
const { Keyring } = require('@polkadot/keyring');
const axios = require('axios');

const wsAddress = 'wss://node3.functionyard.fula.network';

const initApi = async () => {
    const provider = new WsProvider(wsAddress);
    const api = await ApiPromise.create({ provider });
    return api;
};

const fetchPools = async (api) => {
    const pools = { pools: [] };
    const lastPoolId = await api.query.pool.lastPoolId();
    const finalReturnedId = Number(lastPoolId.toHuman());
    for (let i = 1; i <= finalReturnedId; i++) {
        const poolInfo = await api.query.pool.pools(i);
        if (poolInfo) {
            let formattedPoolInfo = poolInfo.toHuman();
            formattedPoolInfo.poolID = i;
            pools.pools.push(formattedPoolInfo);
        }
    }
    return pools;
};

const fetchUserPoolStatus = async (api, accountId) => {
    const poolUsers = await api.query.pool.users(accountId);
    if (poolUsers) {
        console.log({ poolUsers: poolUsers });
        let formattedPoolUsers = poolUsers.toHuman();
        return formattedPoolUsers;
    }
    return null;
};

const getSeed = async () => {
    const response = await axios.get('/api/account/seed');
    return response.data.accountSeed;
};

const joinPool = async (api, seed, poolID, peerId) => {
    console.log('joinPool in polkadotjs with poolID=' + poolID + ' & peerId=' + peerId);
    const keyring = new Keyring({ type: 'sr25519' });
    console.log('keyring generated');
    const userKey = keyring.addFromUri(seed, { name: 'account' }, 'sr25519');
    console.log({ userKey: userKey });
    const balance = await api.query.system.account(userKey.address);
    console.log({ balance: balance });
    if (balance.data.free > 999999999999) {
        console.log('gas balance is: ' + balance.data.free);
        const extrinsic = api.tx.pool.join(poolID, peerId);
        await extrinsic.signAndSend(userKey);
        console.log('join transaction submitted');
    } else {
        alert('You need to first join the testnet. Your balance is below the required threshold.');
    }
};

const leavePool = async (api, seed, poolID) => {
    const keyring = new Keyring({ type: 'sr25519' });
    const userKey = keyring.addFromUri(seed);
    const extrinsic = api.tx.pool.leavePool(poolID, null);
    await extrinsic.signAndSend(userKey);
};

const cancelJoinPool = async (api, seed, poolID) => {
    const keyring = new Keyring({ type: 'sr25519' });
    const userKey = keyring.addFromUri(seed);
    const extrinsic = api.tx.pool.cancelJoin(poolID, null);
    await extrinsic.signAndSend(userKey);
};

module.exports = {
    initApi,
    fetchPools,
    fetchUserPoolStatus,
    getSeed,
    joinPool,
    leavePool,
    cancelJoinPool
};
