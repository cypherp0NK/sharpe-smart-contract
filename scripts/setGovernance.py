from brownie import accounts, SharpeAI, SharpeKeeper, config, manualKeeper

vault = SharpeAI[-1]
def main():
    account = accounts.load("cypherp0NK")
    vault.setGovernance(accounts[2], {"from": account})
    vault.acceptGovernance({"from": accounts[2]})