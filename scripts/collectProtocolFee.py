from brownie import accounts, SharpeAI
def main():
    account = accounts.load("cypherp0NK")
    vault = SharpeAI[-1]
    fee = vault.collectProtocol(3e15, {"from": account})
