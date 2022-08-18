from brownie import accounts, config, SharpeKeeper
import web3
from web3 import Web3
w3 = Web3(Web3.HTTPProvider("https://eth-rinkeby.alchemyapi.io/v2/df8EeLhkeghe4I-OY-zseSWr7aJseYwt"))

interval = 43200

vault = "0x9db685d9E4f2e5A7fAEC5760F2946C32c8422b91"
baseThreshold = 100
limitThreshold = 20
maxTwapDeviation = 100
twapDuration = 60

def main():
    account = accounts.load("cypherp0NK")
    sharpe_keeper = account.deploy(SharpeKeeper, interval, vault, baseThreshold, limitThreshold,maxTwapDeviation,twapDuration,publish_source=True) 
    print (sharpe_keeper)
    