from brownie import accounts, Sharpe, SharpeKeeper
# the manualKeeper contract can be used to run rebalance off-chain without the chainlink keepers

vault = Sharpe[-1]
strategy = SharpeKeeper[-1]
# strategy = manualKeeper[-1]
def main():
    account = accounts.load("cypherp0NK")
    
    print(vault)
    vault.setSharpeKeeper(strategy, {"from": account})
