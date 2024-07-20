import PeerId from 'peer-id';
import { Buffer } from 'buffer';

// Function to create seed from signature and password
export function createSeed(signature, password) {
    const seedString = `${signature}${password}`;
    return Buffer.from(seedString).toString('base64');
}