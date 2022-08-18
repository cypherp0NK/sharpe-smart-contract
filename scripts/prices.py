from brownie import project, config

POOL = "0x77BAEEB630da5bc5DabdBd15eeB84A37E473fFb3" #weth/dai

SECONDS_AGO = 60

def main():
    UniswapV3Core = project.load("Uniswap/uniswap-v3-core@1.0.0")
    pool = UniswapV3Core.interface.IUniswapV3Pool(POOL)
    print (project)
    (before, after), _ = pool.observe([SECONDS_AGO, 0])
    twap = (after - before) / SECONDS_AGO
    last = pool.slot0()[1]
    print (twap)
    
    print (pool.slot0())
   
    weth_dai = (1/1.0001**twap)
    print(weth_dai)
    dai_weth = (1.0001**twap)
    print(dai_weth)
    print ()
    print("=========")

    print(f"twap\t{twap}\t{1.0001**twap}")
    print(f"last\t{last}\t{1.0001**last}")
    print(f"trend\t{last-twap}")