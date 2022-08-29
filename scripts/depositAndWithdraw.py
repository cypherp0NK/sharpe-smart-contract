from brownie import accounts, Token, Sharpe, config
def main():
    account = accounts.load("cypherp0NK")
    vault = Sharpe[-1]
    print(vault)
    Token.at(vault.token0()).approve(vault, 1e18, {"from": account})
    Token.at(vault.token1()).approve(vault, 1e18, {"from": account})
    tx = vault.deposit(5e5, 5e17, 0, 0, account.address, {"from": account})