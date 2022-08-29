from brownie import accounts, config, SharpeKeeper
import web3
from web3 import Web3
w3 = Web3(Web3.HTTPProvider("https://eth-rinkeby.alchemyapi.io/v2/df8EeLhkeghe4I-OY-zseSWr7aJseYwt"))

interval = 43200

vault = "0xeb24a13d7783eEd5716d30e06602083aE09f6DFD"
baseThreshold = 100 #2
limitThreshold = 20 #1
maxTwapDeviation = 100
twapDuration = 60

def main():
    account = accounts.load("cypherp0NK")
    sharpe_keeper = account.deploy(SharpeKeeper, interval, vault, baseThreshold, limitThreshold,maxTwapDeviation,twapDuration,publish_source=True) 
    print (sharpe_keeper)
    