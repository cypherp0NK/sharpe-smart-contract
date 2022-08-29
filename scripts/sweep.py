from brownie import accounts, Sharpe
# This script takes out any foreign token in the vault
def main():
    account = accounts.load("cypherp0NK")
    vault = Sharpe[-1]
    tx = vault.sweep("0xa36085F69e2889c224210F603D836748e7dC0088", 10e18, account.address, {"from": account})
    print(tx)