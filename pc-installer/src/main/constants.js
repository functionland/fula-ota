const path = require('path');
const os = require('os');

module.exports = {
  PORTS: {
    kuboSwarm: 4001,
    kuboApi: 5001,
    kuboLocalApi: 5002,
    kuboGateway: 8080,
    kuboDebug: 8081,
    clusterApi: 9094,
    clusterProxy: 9095,
    clusterSwarm: 9096,
    goFulaLibp2p: 40001,
    goFulaWap: 3500,
    blockchainProxy: 4020,
    blockchainProxyAlt: 4021,
    fulaGateway: 9000,
    fulaPinning: 3501,
  },

  CONTAINERS: {
    watchtower: 'fula_updater',
    kubo: 'ipfs_host',
    kuboLocal: 'ipfs_local',
    cluster: 'ipfs_cluster',
    goFula: 'fula_go',
    fxsupport: 'fula_fxsupport',
    pinning: 'fula_pinning',
    gateway: 'fula_gateway',
  },

  RELAY_PEER_ID: '12D3KooWDRrBaAfPwsGJivBoUw5fE7ZpDiyfUjqgiURq2DEcL835',

  RELAY_ADDR:
    '/dns/relay.dev.fx.land/tcp/4001/p2p/12D3KooWDRrBaAfPwsGJivBoUw5fE7ZpDiyfUjqgiURq2DEcL835',

  BOOTSTRAP_PEERS: [
    '/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN',
    '/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa',
    '/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb',
    '/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt',
    '/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ',
    '/ip4/104.131.131.82/udp/4001/quic-v1/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ',
    '/ip4/172.65.0.13/tcp/4009/p2p/QmcfgsJsMtx6qJb74akCw1M24X1zFwgGo11h1cuhwQjtJP',
  ],

  BLOCKCHAIN_ENDPOINT: 'api.node3.functionyard.fula.network',

  HEALTH_CHECK_INTERVAL: 60000,

  COMPOSE_PROJECT: 'fula',

  MIN_DISK_SPACE_GB: 20,

  TRAY_COLORS: {
    red: 'Error — containers not running',
    green: 'Healthy — all services running',
    yellow: 'Warning — some services degraded',
    blue: 'Starting up...',
    purple: 'Updating containers...',
    cyan: 'Syncing data...',
    grey: 'Stopped',
  },

  DEFAULT_DATA_DIR_WIN: path.join(
    process.env.LOCALAPPDATA || '',
    'FulaData'
  ),

  DEFAULT_DATA_DIR_LINUX: path.join(os.homedir(), '.fula-data'),
};
