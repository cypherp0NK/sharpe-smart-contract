from brownie import accounts, SharpeKeeper

interval = 43200

vault = "0x9e6A7B0532184c7Eb7DC536E1cA7c7606B299a8f"
baseThreshold = 100 #2
limitThreshold = 20 #1


def main():
    account = accounts.load("cypherp0NK")
    sharpe_keeper = account.deploy(SharpeKeeper, interval, vault, baseThreshold, limitThreshold,publish_source=True) 
    print (sharpe_keeper)
    
