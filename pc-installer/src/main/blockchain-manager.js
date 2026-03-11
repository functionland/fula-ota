/**
 * BlockchainManager - Smart contract interaction for pool joining.
 *
 * Replicates the pool join flow from fx/apps/box using ethers.js v5
 * with local wallet signing (no WalletConnect needed).
 *
 * Contract addresses from fx/apps/box/src/contracts/config.ts.
 * ABI subset from fx/apps/box/src/contracts/abis.ts.
 */

const { ethers } = require('ethers');

// Chain configurations matching fx/apps/box/src/contracts/config.ts
const CHAIN_CONFIGS = {
  base: {
    name: 'Base',
    rpcUrl: 'https://base-rpc.publicnode.com',
    rpcFallbacks: [
      'https://1rpc.io/base',
      'https://mainnet.base.org',
    ],
    blockExplorer: 'https://basescan.org',
    contracts: {
      poolStorage: '0xb093fF4B3B3B87a712107B26566e0cCE5E752b4D',
      fulaToken: '0x9e12735d77c72c5C3670636D428f2F3815d8A4cB',
    },
  },
  skale: {
    name: 'SKALE Europa Hub',
    rpcUrl: 'https://mainnet.skalenodes.com/v1/elated-tan-skat',
    rpcFallbacks: [],
    blockExplorer: 'https://elated-tan-skat.explorer.mainnet.skalenodes.com',
    contracts: {
      poolStorage: '0xf9176Ffde541bF0aa7884298Ce538c471Ad0F015',
      fulaToken: '0x9e12735d77c72c5C3670636D428f2F3815d8A4cB',
    },
  },
};

// Minimal ABIs — only the functions we call
const POOL_STORAGE_ABI = [
  // pools(uint32) → view
  {
    inputs: [{ internalType: 'uint32', name: '', type: 'uint32' }],
    name: 'pools',
    outputs: [
      { internalType: 'address', name: 'creator', type: 'address' },
      { internalType: 'uint32', name: 'id', type: 'uint32' },
      { internalType: 'uint32', name: 'maxChallengeResponsePeriod', type: 'uint32' },
      { internalType: 'uint32', name: 'memberCount', type: 'uint32' },
      { internalType: 'uint32', name: 'maxMembers', type: 'uint32' },
      { internalType: 'uint256', name: 'requiredTokens', type: 'uint256' },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  // joinPoolRequest(uint32 poolId, bytes32 peerId)
  {
    inputs: [
      { internalType: 'uint32', name: 'poolId', type: 'uint32' },
      { internalType: 'bytes32', name: 'peerId', type: 'bytes32' },
    ],
    name: 'joinPoolRequest',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  // Custom errors from the contract
  { inputs: [], name: 'PNF', type: 'error' },
  { inputs: [], name: 'AIP', type: 'error' },
  { inputs: [], name: 'ARQ', type: 'error' },
  { inputs: [], name: 'CR', type: 'error' },
  { inputs: [], name: 'IA', type: 'error' },
  { inputs: [], name: 'UF', type: 'error' },
];

const ERC20_ABI = [
  // balanceOf(address) → view
  {
    inputs: [{ internalType: 'address', name: 'account', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  // allowance(address owner, address spender) → view
  {
    inputs: [
      { internalType: 'address', name: 'owner', type: 'address' },
      { internalType: 'address', name: 'spender', type: 'address' },
    ],
    name: 'allowance',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
  // approve(address spender, uint256 amount) → nonpayable
  {
    inputs: [
      { internalType: 'address', name: 'spender', type: 'address' },
      { internalType: 'uint256', name: 'value', type: 'uint256' },
    ],
    name: 'approve',
    outputs: [{ internalType: 'bool', name: '', type: 'bool' }],
    stateMutability: 'nonpayable',
    type: 'function',
  },
];

// Gas limits from fx/apps/box/src/contracts/config.ts
const GAS_LIMITS = {
  joinPool: 1_000_000,
  approve: 200_000,
};

// Solidity custom error → human-readable message
const CUSTOM_ERROR_MESSAGES = {
  PNF: 'Pool not found. Verify the pool ID exists on the selected chain.',
  AIP: 'Already in pool. This peer ID is already a member of the pool.',
  ARQ: 'Join request already pending. Wait for existing request to be processed.',
  CR: 'Pool capacity reached. The pool has reached its maximum member count.',
  IA: 'Insufficient token allowance. Token approval may have failed.',
  UF: 'Account forfeited. This account has been forfeited from the network.',
};

class BlockchainManager {
  /**
   * @param {string} chain - 'skale' or 'base'
   * @param {string} walletHexKey - Ethereum wallet private key (hex)
   * @param {object} [logger] - Optional logger
   */
  constructor(chain, walletHexKey, logger) {
    if (!CHAIN_CONFIGS[chain]) {
      throw new Error(`Unsupported chain "${chain}". Must be "skale" or "base".`);
    }

    this.chain = chain;
    this.chainConfig = CHAIN_CONFIGS[chain];
    this.logger = logger || console;

    // Create provider with timeout
    this.provider = new ethers.providers.JsonRpcProvider({
      url: this.chainConfig.rpcUrl,
      timeout: 30_000,
    });

    // Create wallet connected to provider
    const normalizedKey = walletHexKey.startsWith('0x') ? walletHexKey : `0x${walletHexKey}`;
    this.wallet = new ethers.Wallet(normalizedKey, this.provider);

    // Create contract instances
    this.poolStorage = new ethers.Contract(
      this.chainConfig.contracts.poolStorage,
      POOL_STORAGE_ABI,
      this.wallet,
    );
    this.fulaToken = new ethers.Contract(
      this.chainConfig.contracts.fulaToken,
      ERC20_ABI,
      this.wallet,
    );
  }

  /**
   * Validate that a pool exists and return its info.
   * @param {number} poolId
   * @returns {Promise<{creator: string, id: number, memberCount: number, maxMembers: number, requiredTokens: ethers.BigNumber}>}
   */
  async validatePool(poolId) {
    this.logger.info(`blockchain: validating pool ${poolId} on ${this.chain}...`);
    try {
      const pool = await this.poolStorage.pools(poolId);

      // A pool with id=0 or creator=0x0 does not exist
      if (!pool.id || pool.id === 0 || pool.creator === ethers.constants.AddressZero) {
        throw new Error(`Pool ${poolId} does not exist on ${this.chainConfig.name}.`);
      }

      this.logger.info(
        `blockchain: pool ${poolId} found — members: ${pool.memberCount}/${pool.maxMembers}, ` +
        `requiredTokens: ${ethers.utils.formatUnits(pool.requiredTokens, 18)} FULA`
      );

      return {
        creator: pool.creator,
        id: pool.id,
        memberCount: pool.memberCount,
        maxMembers: pool.maxMembers,
        requiredTokens: pool.requiredTokens,
      };
    } catch (err) {
      throw this._decodeError(err, 'validatePool');
    }
  }

  /**
   * Check FULA token balance and ensure sufficient allowance for pool joining.
   * Approves tokens if current allowance is insufficient.
   *
   * @param {number} poolId
   * @returns {Promise<void>}
   */
  async ensureTokenApproval(poolId) {
    this.logger.info('blockchain: checking token balance and allowance...');
    try {
      const pool = await this.poolStorage.pools(poolId);
      const requiredTokens = pool.requiredTokens;

      if (requiredTokens.isZero()) {
        this.logger.info('blockchain: pool requires no tokens, skipping approval');
        return;
      }

      // Check balance
      const balance = await this.fulaToken.balanceOf(this.wallet.address);
      this.logger.info(
        `blockchain: FULA balance: ${ethers.utils.formatUnits(balance, 18)}, ` +
        `required: ${ethers.utils.formatUnits(requiredTokens, 18)}`
      );

      if (balance.lt(requiredTokens)) {
        throw new Error(
          `Insufficient FULA token balance. ` +
          `Have: ${ethers.utils.formatUnits(balance, 18)}, ` +
          `need: ${ethers.utils.formatUnits(requiredTokens, 18)}. ` +
          `Fund wallet ${this.wallet.address} with FULA tokens on ${this.chainConfig.name}.`
        );
      }

      // Check existing allowance
      const currentAllowance = await this.fulaToken.allowance(
        this.wallet.address,
        this.chainConfig.contracts.poolStorage,
      );

      if (currentAllowance.gte(requiredTokens)) {
        this.logger.info('blockchain: sufficient allowance already set');
        return;
      }

      // Approve the exact required amount
      this.logger.info(
        `blockchain: approving ${ethers.utils.formatUnits(requiredTokens, 18)} FULA ` +
        `for pool storage contract...`
      );

      const approveTx = await this.fulaToken.approve(
        this.chainConfig.contracts.poolStorage,
        requiredTokens,
        { gasLimit: GAS_LIMITS.approve },
      );

      this.logger.info(`blockchain: approve tx sent: ${approveTx.hash}`);
      const receipt = await approveTx.wait();

      if (receipt.status !== 1) {
        throw new Error(`Token approval transaction reverted. Tx: ${approveTx.hash}`);
      }

      this.logger.info(`blockchain: approval confirmed in block ${receipt.blockNumber}`);
    } catch (err) {
      throw this._decodeError(err, 'ensureTokenApproval');
    }
  }

  /**
   * Send a joinPoolRequest transaction.
   *
   * @param {number} poolId
   * @param {string} peerIdBytes32 - 0x-prefixed hex of 32-byte peer public key
   * @returns {Promise<{txHash: string, blockNumber: number}>}
   */
  async joinPool(poolId, peerIdBytes32) {
    this.logger.info(`blockchain: joining pool ${poolId} with peer ${peerIdBytes32.slice(0, 10)}...`);
    try {
      const tx = await this.poolStorage.joinPoolRequest(
        poolId,
        peerIdBytes32,
        { gasLimit: GAS_LIMITS.joinPool },
      );

      this.logger.info(`blockchain: joinPoolRequest tx sent: ${tx.hash}`);
      this.logger.info(`blockchain: waiting for confirmation...`);

      const receipt = await tx.wait();

      if (receipt.status !== 1) {
        throw new Error(`joinPoolRequest transaction reverted. Tx: ${tx.hash}`);
      }

      this.logger.info(
        `blockchain: pool join confirmed in block ${receipt.blockNumber}. ` +
        `Tx: ${this.chainConfig.blockExplorer}/tx/${tx.hash}`
      );

      return { txHash: tx.hash, blockNumber: receipt.blockNumber };
    } catch (err) {
      throw this._decodeError(err, 'joinPool');
    }
  }

  /**
   * Decode contract errors into human-readable messages.
   * @private
   */
  _decodeError(err, context) {
    // Already a clean error message from us
    if (err._decoded) return err;

    const msg = err.message || '';
    const errorData = err.data || err.error?.data || '';

    // Check for known Solidity custom errors
    for (const [errorName, humanMsg] of Object.entries(CUSTOM_ERROR_MESSAGES)) {
      // Custom errors appear as 4-byte selectors in revert data
      const selector = ethers.utils.id(`${errorName}()`).slice(0, 10);
      if (typeof errorData === 'string' && errorData.startsWith(selector)) {
        const decoded = new Error(`${context}: ${humanMsg}`);
        decoded._decoded = true;
        return decoded;
      }
      // Also check error message text (some providers include the error name)
      if (msg.includes(`"${errorName}"`) || msg.includes(`error ${errorName}`)) {
        const decoded = new Error(`${context}: ${humanMsg}`);
        decoded._decoded = true;
        return decoded;
      }
    }

    // Check for common RPC errors
    if (msg.includes('NETWORK_ERROR') || msg.includes('could not detect network')) {
      const decoded = new Error(
        `${context}: Cannot connect to ${this.chainConfig.name} RPC (${this.chainConfig.rpcUrl}). ` +
        `Check your internet connection.`
      );
      decoded._decoded = true;
      return decoded;
    }

    if (msg.includes('insufficient funds') || msg.includes('INSUFFICIENT_FUNDS')) {
      const decoded = new Error(
        `${context}: Insufficient native token for gas on ${this.chainConfig.name}. ` +
        (this.chain === 'skale'
          ? 'SKALE has zero gas fees but requires sFUEL. Get sFUEL from the SKALE faucet.'
          : `Fund wallet ${this.wallet.address} with ETH on Base.`)
      );
      decoded._decoded = true;
      return decoded;
    }

    return err;
  }
}

module.exports = { BlockchainManager, CHAIN_CONFIGS };
