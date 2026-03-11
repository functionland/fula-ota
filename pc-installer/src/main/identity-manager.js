/**
 * IdentityManager - Derives Fula node identity from wallet + password,
 * replicating the exact flow from fula-sec (TypeScript) + go-fula (Go).
 *
 * Identity derivation chain:
 *   1. HDKEY(password) → chainCode (fula-sec)
 *   2. wallet.signMessage(chainCode) → signature (EIP-191 personal_sign)
 *   3. HDKEY.createEDKeyPair(signature) → secretKey (64 bytes)
 *   4. hardwareID + secretKey.toString() → combinedSeed (go-fula server.go)
 *   5. SHA256(combinedSeed) → Ed25519 seed → private key (go-fula properties.go)
 *   6. protobuf_marshal(privKey) → base64 identity (libp2p format)
 *   7. HMAC-SHA256(seed, "fula-kubo-identity-v1") → kubo peer ID (go-fula main.go)
 *   8. peer.IDFromPrivateKey(identity) → cluster peer ID
 */

const crypto = require('crypto');
const bs58 = require('bs58');

/**
 * Replicate fula-sec HDKEY._splitKey(password):
 *   keccak256(password) → hexSeed
 *   HMAC-SHA512("ed25519 seed", hexSeed) → [IL (32 bytes), IR (32 bytes)]
 *   chainCode = base64pad(IR)
 *
 * @param {string} password
 * @returns {{ key: Buffer, chainCode: Buffer, chainCodeBase64: string }}
 */
function hdkeySplitKey(password) {
  const { keccak256 } = require('js-sha3');
  const hexSeed = keccak256(password);

  const hmac = crypto.createHmac('sha512', Buffer.from('ed25519 seed'));
  hmac.update(Buffer.from(hexSeed, 'hex'));
  const secretKey = hmac.digest();

  const IL = secretKey.subarray(0, 32);
  const IR = secretKey.subarray(32);

  return {
    key: IL,
    chainCode: IR,
    chainCodeBase64: IR.toString('base64'), // base64pad equivalent
  };
}

/**
 * Replicate fula-sec HDKEY.createEDKeyPair(signedKey):
 *   base64pad(IL) + signedKey → keccak256 → hexSeed
 *   HMAC-SHA512("ed25519 seed", hexSeed) → 64-byte secretKey
 *
 * @param {Buffer} key - IL from _splitKey
 * @param {string} signedKey - hex signature from wallet
 * @returns {Buffer} 64-byte secret key (HMAC-SHA512 output)
 */
function createEDKeyPair(key, signedKey) {
  const { keccak256 } = require('js-sha3');

  const keyBase64 = key.toString('base64');
  const hexSeed = keccak256(keyBase64 + signedKey);

  const hmac = crypto.createHmac('sha512', Buffer.from('ed25519 seed'));
  hmac.update(Buffer.from(hexSeed, 'hex'));
  return hmac.digest(); // 64 bytes
}

/**
 * Marshal an Ed25519 private key in libp2p protobuf format.
 *
 * go-libp2p crypto.MarshalPrivateKey():
 *   field 1 (Type) = varint 1 (Ed25519)  → 0x08 0x01
 *   field 2 (Data) = bytes, length 64     → 0x12 0x40 ...64b
 *
 * @param {Buffer} privKeyBytes - 64-byte Ed25519 private key (seed + pubkey)
 * @returns {Buffer}
 */
function marshalEd25519PrivateKey(privKeyBytes) {
  return Buffer.concat([
    Buffer.from([0x08, 0x01, 0x12, 0x40]),
    privKeyBytes,
  ]);
}

/**
 * Unmarshal a libp2p protobuf-encoded Ed25519 private key.
 *
 * @param {Buffer} marshaled - protobuf bytes
 * @returns {Buffer} 64-byte raw Ed25519 private key
 */
function unmarshalEd25519PrivateKey(marshaled) {
  if (marshaled[0] !== 0x08 || marshaled[1] !== 0x01 ||
      marshaled[2] !== 0x12 || marshaled[3] !== 0x40) {
    throw new Error('Invalid libp2p Ed25519 private key format');
  }
  return marshaled.subarray(4, 4 + 64);
}

/**
 * Marshal an Ed25519 public key in libp2p protobuf format.
 *   field 1 (Type) = varint 1 (Ed25519)  → 0x08 0x01
 *   field 2 (Data) = bytes, length 32     → 0x12 0x20 ...32b
 *
 * @param {Buffer} pubKeyBytes - 32-byte Ed25519 public key
 * @returns {Buffer}
 */
function marshalEd25519PublicKey(pubKeyBytes) {
  return Buffer.concat([
    Buffer.from([0x08, 0x01, 0x12, 0x20]),
    pubKeyBytes,
  ]);
}

/**
 * Compute a libp2p peer ID from an Ed25519 public key.
 *
 * For Ed25519 keys (<=42 bytes marshaled), libp2p uses an "identity" multihash:
 *   [0x00 (identity hash fn), 0x24 (length=36), ...marshaled_pubkey(36 bytes)]
 *
 * The result is base58btc-encoded. Peer IDs are displayed without multibase prefix.
 *
 * @param {Buffer} pubKeyBytes - 32-byte Ed25519 public key
 * @returns {string} peer ID string (e.g. "12D3KooW...")
 */
function peerIdFromEd25519PublicKey(pubKeyBytes) {
  const marshaledPubKey = marshalEd25519PublicKey(pubKeyBytes);
  // Identity multihash: [0x00, length, ...data]
  const multihash = Buffer.concat([
    Buffer.from([0x00, marshaledPubKey.length]),
    marshaledPubKey,
  ]);

  return bs58.encode(multihash);
}

/**
 * Derive a complete Fula node identity from wallet private key + password.
 *
 * @param {string} password - User's password
 * @param {string} walletHexKey - Ethereum wallet private key (hex, with or without 0x)
 * @param {string} hardwareID - SHA256 hash of MAC address (64-char hex)
 * @returns {Promise<{identity: string, kuboPeerId: string, clusterPeerId: string, edSeed: Buffer}>}
 */
async function deriveIdentity(password, walletHexKey, hardwareID) {
  const { Wallet } = require('ethers');
  const nacl = require('tweetnacl');

  // Step 1: HDKEY._splitKey(password) → { key (IL), chainCode (IR) }
  const { key, chainCodeBase64 } = hdkeySplitKey(password);

  // Step 2: wallet.signMessage(chainCode) — EIP-191 personal_sign
  const wallet = new Wallet(walletHexKey);
  const signature = await wallet.signMessage(chainCodeBase64);

  // Step 3: HDKEY.createEDKeyPair(signature) → 64-byte secretKey
  const secretKey = createEDKeyPair(key, signature);

  // Step 4: The mobile app sends secretKey.toString() to go-fula,
  // which is JS Uint8Array.toString() → "1,2,3,..." format.
  // go-fula does: combinedSeed = hardwareID + seedString
  const seedString = Array.from(secretKey).join(',');
  const combinedSeed = hardwareID + seedString;

  // Step 5: SHA256(combinedSeed) → 32-byte Ed25519 seed
  const edSeed = crypto.createHash('sha256').update(combinedSeed).digest();

  // Step 6: Generate Ed25519 private key from seed (64 bytes: seed + pubkey)
  const keyPair = nacl.sign.keyPair.fromSeed(edSeed);
  const edPrivKey = Buffer.from(keyPair.secretKey); // 64 bytes

  // Step 7: Marshal to libp2p format → base64 identity
  const marshaledPrivKey = marshalEd25519PrivateKey(edPrivKey);
  const identity = marshaledPrivKey.toString('base64');

  // Step 8: Derive cluster peer ID (from the identity private key)
  const clusterPubKey = Buffer.from(keyPair.publicKey); // 32 bytes
  const clusterPeerId = peerIdFromEd25519PublicKey(clusterPubKey);

  // Step 9: Derive kubo peer ID via HMAC-SHA256
  const kuboPeerId = deriveKuboPeerId(edSeed);

  return { identity, kuboPeerId, clusterPeerId, edSeed };
}

/**
 * Derive the kubo peer ID from the original Ed25519 seed.
 * Matches go-fula/cmd/blox/main.go deriveKuboKey():
 *   HMAC-SHA256(key="fula-kubo-identity-v1", data=originalSeed) → derivedSeed
 *   Ed25519 from derivedSeed → kubo key pair → peer ID
 *
 * Note: crypto.GenerateEd25519Key(reader) in Go reads exactly 32 bytes
 * from the reader to use as the Ed25519 seed.
 *
 * @param {Buffer} originalSeed - 32-byte Ed25519 seed
 * @returns {string} kubo peer ID string
 */
function deriveKuboPeerId(originalSeed) {
  const nacl = require('tweetnacl');

  const mac = crypto.createHmac('sha256', Buffer.from('fula-kubo-identity-v1'));
  mac.update(originalSeed);
  const derivedSeed = mac.digest(); // 32 bytes

  const kuboKeyPair = nacl.sign.keyPair.fromSeed(derivedSeed);
  const kuboPubKey = Buffer.from(kuboKeyPair.publicKey);

  return peerIdFromEd25519PublicKey(kuboPubKey);
}

/**
 * Convert a peer ID to bytes32 format for smart contract usage.
 * Ported from fx/apps/box/src/utils/peerIdConversion.ts.
 *
 * @param {string} peerId - Peer ID string (e.g. "12D3KooW...")
 * @returns {string} hex string of 32-byte public key (0x-prefixed)
 */
function peerIdToBytes32(peerId) {
  const decoded = bs58.decode(peerId);

  // CIDv1 (Ed25519 public key) format: [0x00, 0x24, 0x08, 0x01, 0x12, ...]
  const CID_HEADER = [0x00, 0x24, 0x08, 0x01, 0x12];
  const isCIDv1 = CID_HEADER.every((v, i) => decoded[i] === v);

  if (isCIDv1 && decoded.length >= 37) {
    const pubkey = decoded.slice(decoded.length - 32);
    return '0x' + Buffer.from(pubkey).toString('hex');
  }

  // Legacy multihash format: [0x12, 0x20, ...32 bytes]
  if (decoded.length === 34 && decoded[0] === 0x12 && decoded[1] === 0x20) {
    const digest = decoded.slice(2);
    return '0x' + Buffer.from(digest).toString('hex');
  }

  throw new Error(`Unsupported PeerID format or unexpected length: ${decoded.length}`);
}

module.exports = {
  deriveIdentity,
  deriveKuboPeerId,
  peerIdToBytes32,
  peerIdFromEd25519PublicKey,
  marshalEd25519PrivateKey,
  unmarshalEd25519PrivateKey,
  hdkeySplitKey,
  createEDKeyPair,
};
