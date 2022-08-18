from brownie import accounts, config, SharpeAI
from web3 import Web3

# POOL = "0xDaC8A8E6DBf8c690ec6815e0fF03491B2770255D" #0.01
# POOL = "0xbEAf7156bA07C3dF8FAc42E90188c5a752470DB7" #usdc / usdt pool 0.05 
# POOL = "0x7F567cE133B0B69458fC318af06Eee27642865be" #usdc / miMatic pool 0.05
POOL = "0x77BAEEB630da5bc5DabdBd15eeB84A37E473fFb3" #kovan
ROUTER = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45" #kovan
PROTOCOL_FEE = 5000
MAX_SUPPLY = 4.0501570943229e+21

w3 = Web3(Web3.HTTPProvider("https://polygon-mainnet.g.alchemy.com/v2/2VsZl1VcrmWJ44CvrD9pt1HFieK6TQfZ"))

def main():
    account = accounts.load("cypherp0NK")
    vault = account.deploy(SharpeAI, POOL, ROUTER, PROTOCOL_FEE, MAX_SUPPLY)