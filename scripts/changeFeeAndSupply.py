from brownie import accounts, Sharpe
def main():
    PROTOCOL_FEE = 2000
    MAX_SUPPLY = 10.0501570943229e+21

    account = accounts.load("cypherp0NK")
    vault = Sharpe[-1]
    tx = vault.setProtocolFee(PROTOCOL_FEE, {"from": account})
    supply = vault.setMaxTotalSupply(MAX_SUPPLY, {"from": account})