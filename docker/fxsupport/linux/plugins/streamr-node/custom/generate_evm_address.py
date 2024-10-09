import eth_account
from eth_account import Account
import sys

def generate_evm_address(private_key):
    # Remove '0x' prefix if present
    if private_key.startswith('0x'):
        private_key = private_key[2:]
    
    try:
        # Create an account object from the private key
        account = Account.from_key(private_key)
        
        # Get the address
        address = account.address
        
        return address
    except ValueError as e:
        return f"Error: {str(e)}"

if __name__ == "__main__":
    # Check if a private key was provided as a command-line argument
    if len(sys.argv) > 1:
        private_key = sys.argv[1]
    else:
        # If not provided as an argument, prompt the user
        private_key = input("Enter your private key (with or without '0x' prefix): ")

    address = generate_evm_address(private_key)
    print(address)