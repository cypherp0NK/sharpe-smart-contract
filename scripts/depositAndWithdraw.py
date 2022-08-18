from brownie import accounts, Token, SharpeAI, config
def main():
    account = accounts.load("cypherp0NK")
    vault = SharpeAI[-1]
    Token.at(vault.token0()).approve(vault, 2e18, {"from": account})
    Token.at(vault.token1()).approve(vault, 2e17, {"from": account})
    tx = vault.deposit(2e18, 2e17, 0, 0, account.address, {"from": account})