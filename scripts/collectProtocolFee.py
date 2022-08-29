from brownie import accounts, Sharpe
def main():
    account = accounts.load("cypherp0NK")
    vault = Sharpe[-1]
    fee = vault.collectProtocol(3e15, {"from": account})
