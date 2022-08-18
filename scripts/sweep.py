from brownie import accounts, SharpeAI
# This script takes any foreign token out of the vault
def main():
    account = accounts.load("cypherp0NK")
    vault = SharpeAI[-1]
    tx = vault.sweep("0xa36085F69e2889c224210F603D836748e7dC0088", 10e18, account.address, {"from": account})
    print(tx)