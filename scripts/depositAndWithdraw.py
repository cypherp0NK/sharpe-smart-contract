from brownie import accounts, Token, Sharpe
def main():
    account = accounts.load("cypherp0NK")
    vault = Sharpe[-1]
    print(vault)
    # Token.at(vault.token0()).approve(vault, 1e18, {"from": account})
    # Token.at(vault.token1()).approve(vault, 10e18, {"from": account})
    # tx = vault.deposit(8.44242e6, 0, 3.6e6, 3.6e6, account.address, {"from": account})
    tx = vault.withdraw(0.000000000004199296e18, 0, 7e6, account.address, 2, {"from": account})
