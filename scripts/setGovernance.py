from brownie import accounts, Sharpe
vault = Sharpe[-1]
def main():
    account = accounts.load("cypherp0NK")
    vault.setGovernance(accounts[2], {"from": account})
    vault.acceptGovernance({"from": accounts[2]})